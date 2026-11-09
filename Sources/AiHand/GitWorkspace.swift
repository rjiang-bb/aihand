import Foundation
import SwiftUI

struct GitDiffStat: Equatable {
    var insertions: Int = 0
    var deletions: Int = 0

    var isEmpty: Bool { insertions == 0 && deletions == 0 }
}

struct GitWorktreeEntry: Identifiable, Equatable {
    var id: String { path }
    /// Absolute worktree path (cwd for agents when selected).
    var path: String
    /// Branch name, or a detached-HEAD label.
    var branch: String
    /// Line diff of this branch vs the repo’s default base (`origin/main`, etc.).
    var diff: GitDiffStat
    /// Staged + unstaged changes vs HEAD in this worktree.
    var workingDiff: GitDiffStat = GitDiffStat()
    /// True for the primary checkout (`repoRoot`), which cannot be removed as a worktree.
    var isPrimary: Bool = false
    /// HEAD commit unix time — used to order recent → oldest.
    var commitTimestamp: TimeInterval = 0

    /// Working-tree dirty stats when present; otherwise branch-vs-base.
    var displayedDiff: GitDiffStat {
        workingDiff.isEmpty ? diff : workingDiff
    }
}

struct GitRepoInfo: Equatable {
    /// Common git dir’s main worktree root (`git rev-parse --show-toplevel` from the registered folder).
    var repoRoot: String
    /// Ref used for branch line diffs (e.g. `origin/main`).
    var baseRef: String?
    var worktrees: [GitWorktreeEntry]

    func entry(forPath path: String) -> GitWorktreeEntry? {
        let key = SessionStore.normalizedWorkspace(path)
        return worktrees.first { SessionStore.sameWorkspace($0.path, key) }
    }
}

struct GitDiffLinesView: View {
    let diff: GitDiffStat

    var body: some View {
        HStack(spacing: 6) {
            if diff.insertions > 0 {
                Text("+\(diff.insertions)")
                    .foregroundStyle(Color(red: 0.45, green: 0.78, blue: 0.55))
            }
            if diff.deletions > 0 {
                Text("-\(diff.deletions)")
                    .foregroundStyle(Color(red: 0.95, green: 0.48, blue: 0.48))
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }
}

enum GitWorkspace {
    /// Cheap check — one `rev-parse`, no worktree/diff walks.
    static func isRepository(path: String, connection: SSHConnection? = nil) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return runGit(["rev-parse", "--is-inside-work-tree"], in: trimmed, connection: connection)?.stdout == "true"
    }

    /// Probe worktrees + branch/working diff stats for a folder. Returns nil when not a git repo.
    static func inspect(path: String, connection: SSHConnection? = nil) -> GitRepoInfo? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let toplevel = runGit(["rev-parse", "--show-toplevel"], in: trimmed, connection: connection)?.stdout else {
            return nil
        }
        let probe = SessionStore.normalizedWorkspace(toplevel)
        guard !probe.isEmpty else { return nil }

        let porcelain = runGit(["worktree", "list", "--porcelain"], in: probe, connection: connection)?.stdout ?? ""
        var entries = parseWorktrees(porcelain)
        let root = entries.first?.path ?? probe
        let base = defaultBaseRef(in: root, connection: connection)
        if entries.isEmpty {
            let branch = currentBranch(in: root, connection: connection) ?? "HEAD"
            entries = [
                GitWorktreeEntry(
                    path: root,
                    branch: branch,
                    diff: branchDiffStat(base: base, in: root, connection: connection),
                    workingDiff: workingDiffStat(in: root, connection: connection),
                    isPrimary: true,
                    commitTimestamp: commitTimestamp(in: root, connection: connection)
                )
            ]
        } else {
            let mainPath = root
            entries = entries.map { entry in
                var next = entry
                if next.branch.isEmpty {
                    next.branch = currentBranch(in: entry.path, connection: connection) ?? "HEAD"
                }
                next.diff = branchDiffStat(base: base, in: entry.path, connection: connection)
                next.workingDiff = workingDiffStat(in: entry.path, connection: connection)
                next.isPrimary = SessionStore.sameWorkspace(next.path, mainPath)
                next.commitTimestamp = commitTimestamp(in: entry.path, connection: connection)
                return next
            }
            entries.sort {
                if $0.commitTimestamp != $1.commitTimestamp {
                    return $0.commitTimestamp > $1.commitTimestamp
                }
                return $0.branch.localizedCaseInsensitiveCompare($1.branch) == .orderedAscending
            }
        }
        return GitRepoInfo(repoRoot: root, baseRef: base, worktrees: entries)
    }

    static func commitTimestamp(in path: String, connection: SSHConnection? = nil) -> TimeInterval {
        guard let raw = runGit(["log", "-1", "--format=%ct"], in: path, connection: connection)?.stdout,
              let value = TimeInterval(raw) else {
            return 0
        }
        return value
    }

    static func currentBranch(in path: String, connection: SSHConnection? = nil) -> String? {
        if let name = runGit(["branch", "--show-current"], in: path, connection: connection)?.stdout, !name.isEmpty {
            return name
        }
        if let short = runGit(["rev-parse", "--short", "HEAD"], in: path, connection: connection)?.stdout, !short.isEmpty {
            return "detached \(short)"
        }
        return nil
    }

    static func workingDiffStat(in path: String, connection: SSHConnection? = nil) -> GitDiffStat {
        var stat = parseNumstat(runGit(["diff", "HEAD", "--numstat"], in: path, connection: connection)?.stdout)
        if let connection {
            // One remote script — never N SSH round-trips (was catastrophic on large untracked trees).
            stat.insertions += remoteUntrackedInsertionTotal(connection: connection, repoPath: path)
            return stat
        }
        guard let listed = runGit(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            in: path,
            connection: nil
        )?.stdout, !listed.isEmpty else {
            return stat
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        for relative in listed.split(separator: "\0", omittingEmptySubsequences: true) {
            let fileURL = root.appendingPathComponent(String(relative))
            stat.insertions += untrackedInsertionCount(at: fileURL)
        }
        return stat
    }

    /// Line-count untracked files in a single SSH invocation.
    private static func remoteUntrackedInsertionTotal(connection: SSHConnection, repoPath: String) -> Int {
        let escaped = SSHClient.shellEscape(repoPath)
        let script = """
        cd \(escaped) || exit 0
        total=0
        while IFS= read -r -d '' f; do
          if [ ! -f "$f" ]; then
            total=$((total + 1))
          elif grep -Iq . "$f" 2>/dev/null; then
            n=$(wc -l < "$f" | tr -d '[:space:]')
            total=$((total + ${n:-1}))
          else
            total=$((total + 1))
          fi
        done < <(git ls-files --others --exclude-standard -z 2>/dev/null)
        printf '%s' "$total"
        """
        let result = SSHClient.runShell(connection, script)
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed) ?? 0
    }

    private static func untrackedInsertionCount(at fileURL: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return 1 }
        defer { try? handle.close() }
        let chunkSize = 64 * 1024
        var newlines = 0
        var sawBytes = false
        var endsWithNewline = false
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            if chunk.contains(0) { return 1 }
            sawBytes = true
            newlines += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            endsWithNewline = chunk.last == 0x0A
        }
        guard sawBytes else { return 1 }
        return endsWithNewline ? newlines : newlines + 1
    }

    static func branchDiffStat(base: String?, in path: String, connection: SSHConnection? = nil) -> GitDiffStat {
        guard let base, !base.isEmpty else { return GitDiffStat() }
        return parseNumstat(runGit(["diff", "--numstat", "\(base)...HEAD"], in: path, connection: connection)?.stdout)
    }

    static func defaultBaseRef(in root: String, connection: SSHConnection? = nil) -> String? {
        if let remote = runGit(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: root, connection: connection)?.stdout,
           !remote.isEmpty {
            return remote
        }
        for candidate in ["origin/main", "origin/master", "main", "master"] {
            if revExists(candidate, in: root, connection: connection) {
                return candidate
            }
        }
        return nil
    }

    static func addWorktree(branch: String, inRepo root: String, connection: SSHConnection? = nil) -> (path: String?, error: String?) {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return (nil, "Enter a branch name.") }
        guard isSafeBranchName(name) else {
            return (nil, "Use letters, numbers, dashes, slashes, or dots in the branch name.")
        }
        guard let info = inspect(path: root, connection: connection) else {
            return (nil, "That folder isn’t a git repository.")
        }
        if info.worktrees.contains(where: { $0.branch == name }) {
            return (nil, "A worktree for “\(name)” already exists.")
        }

        let path = suggestedWorktreePath(repoRoot: info.repoRoot, branch: name)
        if let connection {
            if SSHClient.directoryExists(connection, path: path)
                || SSHClient.runShell(connection, "test -e \(SSHClient.shellEscape(path))").ok {
                return (nil, "Path already exists:\n\(path)")
            }
        } else if FileManager.default.fileExists(atPath: path) {
            return (nil, "Path already exists:\n\(path)")
        }

        let exists = branchExists(name, in: info.repoRoot, connection: connection)
        let args: [String]
        if exists {
            args = ["worktree", "add", path, name]
        } else {
            args = ["worktree", "add", "-b", name, path]
        }
        if let error = runGit(args, in: info.repoRoot, connection: connection)?.error {
            return (nil, error)
        }
        return (SessionStore.normalizedWorkspace(path), nil)
    }

    static func removeWorktree(path: String, inRepo root: String, connection: SSHConnection? = nil) -> String? {
        guard let info = inspect(path: root, connection: connection) else {
            return "That folder isn’t a git repository."
        }
        guard let entry = info.entry(forPath: path) else {
            return "Worktree not found."
        }
        if entry.isPrimary {
            return "The main checkout can’t be removed as a worktree."
        }
        if !entry.workingDiff.isEmpty {
            return "Commit or stash changes before removing this worktree."
        }
        return runGit(["worktree", "remove", entry.path], in: info.repoRoot, connection: connection)?.error
    }

    static func suggestedWorktreePath(repoRoot: String, branch: String) -> String {
        let parent = URL(fileURLWithPath: repoRoot).deletingLastPathComponent()
        let repoName = URL(fileURLWithPath: repoRoot).lastPathComponent
        let slug = branch
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return parent.appendingPathComponent("\(repoName)-\(slug)").path
    }

    private static func parseNumstat(_ output: String?) -> GitDiffStat {
        guard let output else { return GitDiffStat() }
        var insertions = 0
        var deletions = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            insertions += Int(parts[0]) ?? 0
            deletions += Int(parts[1]) ?? 0
        }
        return GitDiffStat(insertions: insertions, deletions: deletions)
    }

    private static func revExists(_ rev: String, in root: String, connection: SSHConnection?) -> Bool {
        runGit(["rev-parse", "--verify", "--quiet", rev], in: root, connection: connection)?.ok == true
    }

    private static func branchExists(_ name: String, in root: String, connection: SSHConnection?) -> Bool {
        runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: root, connection: connection)?.ok == true
    }

    private static func isSafeBranchName(_ name: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/_.-"))
        return !name.isEmpty
            && name.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !name.hasPrefix(".")
            && !name.hasSuffix(".lock")
            && !name.contains("..")
    }

    private static func parseWorktrees(_ porcelain: String) -> [GitWorktreeEntry] {
        var result: [GitWorktreeEntry] = []
        var path = ""
        var branch = ""
        func flush() {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            result.append(
                GitWorktreeEntry(
                    path: SessionStore.normalizedWorkspace(trimmed),
                    branch: branch,
                    diff: GitDiffStat()
                )
            )
            path = ""
            branch = ""
        }
        for raw in porcelain.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("worktree ") {
                if !path.isEmpty { flush() }
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/")
                    ? String(ref.dropFirst("refs/heads/".count))
                    : ref
            } else if line == "detached" {
                branch = ""
            }
        }
        flush()
        return result
    }

    private struct GitRun {
        var ok: Bool
        var stdout: String
        var error: String?
    }

    @discardableResult
    private static func runGit(_ args: [String], in directory: String, connection: SSHConnection? = nil) -> GitRun? {
        if let connection {
            var remoteArgs = ["git", "-C", directory]
            remoteArgs.append(contentsOf: args)
            let result = SSHClient.run(connection, remoteCommand: remoteArgs)
            if result.ok {
                return GitRun(ok: true, stdout: result.stdout, error: nil)
            }
            let message = result.stderr.isEmpty ? "git \(args.first ?? "") failed." : result.stderr
            return GitRun(ok: false, stdout: result.stdout, error: message)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return GitRun(ok: false, stdout: "", error: error.localizedDescription)
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus == 0 {
            return GitRun(ok: true, stdout: stdout, error: nil)
        }
        let message = stderr.isEmpty ? "git \(args.first ?? "") failed." : stderr
        return GitRun(ok: false, stdout: stdout, error: message)
    }
}
