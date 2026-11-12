import Foundation

/// Which slice of a worktree’s history the Changes window shows.
enum WorktreeDiffFilter: Equatable {
    case uncommitted
    case staged
    case unstaged
    case commit(String)

    init?(json: [String: Any]) {
        switch json["kind"] as? String {
        case "uncommitted": self = .uncommitted
        case "staged": self = .staged
        case "unstaged": self = .unstaged
        case "commit":
            guard let sha = json["sha"] as? String, WorktreeDiff.isSafeRev(sha) else { return nil }
            self = .commit(sha)
        default: return nil
        }
    }
}

struct WorktreeChangedFile: Codable, Equatable {
    var path: String
    /// Previous path for renames / copies.
    var oldPath: String?
    /// `A` added, `M` modified, `D` deleted, `R` renamed, `U` untracked.
    var status: String
    var added: Int
    var removed: Int
    var binary: Bool
}

struct WorktreeCommit: Codable, Equatable {
    var sha: String
    var short: String
    var subject: String
    var date: String
}

struct WorktreeFileContent: Equatable {
    var original: String
    var modified: String
    var binary: Bool
    var tooLarge: Bool
}

/// Read-only git queries behind the Changes window (local or over SSH via `GitWorkspace.rawGit`).
enum WorktreeDiff {
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    /// Beyond this we show “too large” instead of shipping both sides to Monaco.
    static let maxBytes = 1_500_000
    private static let maxUntrackedCounted = 400

    static func isSafeRev(_ rev: String) -> Bool {
        !rev.isEmpty && rev.count <= 64 && rev.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }

    // MARK: File lists

    static func files(
        filter: WorktreeDiffFilter,
        in path: String,
        connection: SSHConnection? = nil
    ) -> [WorktreeChangedFile] {
        let args = diffArgs(filter, in: path, connection: connection)
        let numstat = string(GitWorkspace.rawGit(["diff", "-z", "--numstat", "-M", "--no-ext-diff"] + args, in: path, connection: connection))
        let names = string(GitWorkspace.rawGit(["diff", "-z", "--name-status", "-M", "--no-ext-diff"] + args, in: path, connection: connection))
        var files = parseFiles(numstat: numstat, nameStatus: names)
        switch filter {
        case .uncommitted, .unstaged:
            let known = Set(files.map(\.path))
            files += untracked(in: path, connection: connection).filter { !known.contains($0.path) }
        case .staged, .commit:
            break
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Totals for the three working-tree filters (menu badges).
    static func counts(in path: String, connection: SSHConnection? = nil) -> [String: GitDiffStat] {
        func total(_ filter: WorktreeDiffFilter) -> GitDiffStat {
            files(filter: filter, in: path, connection: connection).reduce(into: GitDiffStat()) {
                $0.insertions += $1.added
                $0.deletions += $1.removed
            }
        }
        return [
            "uncommitted": total(.uncommitted),
            "staged": total(.staged),
            "unstaged": total(.unstaged),
        ]
    }

    static func commits(
        in path: String,
        skip: Int = 0,
        limit: Int = 50,
        connection: SSHConnection? = nil
    ) -> [WorktreeCommit] {
        let format = "%H%x1f%h%x1f%s%x1f%cr%x1e"
        let raw = string(GitWorkspace.rawGit(
            ["log", "--skip=\(max(0, skip))", "-n", "\(max(1, limit))", "--format=\(format)"],
            in: path,
            connection: connection
        ))
        return parseCommits(raw)
    }

    // MARK: Contents

    static func content(
        filter: WorktreeDiffFilter,
        file: WorktreeChangedFile,
        in path: String,
        connection: SSHConnection? = nil
    ) -> WorktreeFileContent {
        let oldPath = file.oldPath ?? file.path
        let hasHead = revExists("HEAD", in: path, connection: connection)
        var original: Data?
        var modified: Data?

        switch filter {
        case .uncommitted:
            if file.status != "A" && file.status != "U" && hasHead { original = show("HEAD:\(oldPath)", in: path, connection: connection) }
            if file.status != "D" { modified = working(file.path, in: path, connection: connection) }
        case .staged:
            if file.status != "A" && hasHead { original = show("HEAD:\(oldPath)", in: path, connection: connection) }
            if file.status != "D" { modified = show(":\(file.path)", in: path, connection: connection) }
        case .unstaged:
            if file.status != "A" && file.status != "U" { original = show(":\(oldPath)", in: path, connection: connection) }
            if file.status != "D" { modified = working(file.path, in: path, connection: connection) }
        case .commit(let sha):
            if file.status != "A", revExists("\(sha)^", in: path, connection: connection) {
                original = show("\(sha)^:\(oldPath)", in: path, connection: connection)
            }
            if file.status != "D" { modified = show("\(sha):\(file.path)", in: path, connection: connection) }
        }

        let o = original ?? Data()
        let m = modified ?? Data()
        if o.count > maxBytes || m.count > maxBytes {
            return WorktreeFileContent(original: "", modified: "", binary: false, tooLarge: true)
        }
        if isBinary(o) || isBinary(m) {
            return WorktreeFileContent(original: "", modified: "", binary: true, tooLarge: false)
        }
        return WorktreeFileContent(
            original: String(decoding: o, as: UTF8.self),
            modified: String(decoding: m, as: UTF8.self),
            binary: false,
            tooLarge: false
        )
    }

    // MARK: Parsing (pure — unit tested)

    /// `git diff -z --numstat -M` + `--name-status -M` → files.
    static func parseFiles(numstat: String, nameStatus: String) -> [WorktreeChangedFile] {
        struct Stat { var added = 0; var removed = 0; var binary = false }
        var stats: [String: Stat] = [:]
        var order: [String] = []

        let nt = numstat.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < nt.count {
            let record = nt[i]
            i += 1
            if record.isEmpty { continue }
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            var filePath = parts[2]
            if filePath.isEmpty {
                // Rename: next two tokens are old, new.
                guard i + 1 < nt.count else { break }
                filePath = nt[i + 1]
                i += 2
            }
            let binary = parts[0] == "-" && parts[1] == "-"
            stats[filePath] = Stat(added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0, binary: binary)
            order.append(filePath)
        }

        var result: [WorktreeChangedFile] = []
        let ns = nameStatus.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var j = 0
        while j < ns.count {
            let code = ns[j]
            j += 1
            guard let first = code.first else { continue }
            var oldPath: String?
            var newPath: String
            if first == "R" || first == "C" {
                guard j + 1 < ns.count else { break }
                oldPath = ns[j]
                newPath = ns[j + 1]
                j += 2
            } else {
                guard j < ns.count else { break }
                newPath = ns[j]
                j += 1
            }
            let stat = stats[newPath] ?? Stat()
            let status: String
            switch first {
            case "A": status = "A"
            case "D": status = "D"
            case "R", "C": status = "R"
            default: status = "M"
            }
            result.append(WorktreeChangedFile(
                path: newPath, oldPath: oldPath, status: status,
                added: stat.added, removed: stat.removed, binary: stat.binary
            ))
        }
        // Numstat-only entries (shouldn’t happen) still show up.
        let seen = Set(result.map(\.path))
        for path in order where !seen.contains(path) {
            let s = stats[path] ?? Stat()
            result.append(WorktreeChangedFile(path: path, oldPath: nil, status: "M", added: s.added, removed: s.removed, binary: s.binary))
        }
        return result
    }

    static func parseCommits(_ raw: String) -> [WorktreeCommit] {
        raw.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record in
            let parts = record.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, !parts[0].isEmpty else { return nil }
            return WorktreeCommit(sha: parts[0], short: parts[1], subject: parts[2], date: parts[3])
        }
    }

    // MARK: Private

    private static func diffArgs(_ filter: WorktreeDiffFilter, in path: String, connection: SSHConnection?) -> [String] {
        let head = revExists("HEAD", in: path, connection: connection) ? "HEAD" : emptyTree
        switch filter {
        case .uncommitted: return [head]
        case .staged: return ["--cached", head]
        case .unstaged: return []
        case .commit(let sha):
            let parent = revExists("\(sha)^", in: path, connection: connection) ? "\(sha)^" : emptyTree
            return [parent, sha]
        }
    }

    private static func untracked(in path: String, connection: SSHConnection?) -> [WorktreeChangedFile] {
        let listed = string(GitWorkspace.rawGit(["ls-files", "--others", "--exclude-standard", "-z"], in: path, connection: connection))
        let names = listed.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        let root = URL(fileURLWithPath: path, isDirectory: true)
        return names.enumerated().map { index, name in
            let lines = connection == nil && index < maxUntrackedCounted
                ? GitWorkspace.untrackedInsertionCount(at: root.appendingPathComponent(name))
                : 0
            return WorktreeChangedFile(path: name, oldPath: nil, status: "U", added: lines, removed: 0, binary: false)
        }
    }

    private static func revExists(_ rev: String, in path: String, connection: SSHConnection?) -> Bool {
        GitWorkspace.rawGit(["rev-parse", "--verify", "--quiet", rev], in: path, connection: connection) != nil
    }

    private static func show(_ spec: String, in path: String, connection: SSHConnection?) -> Data? {
        GitWorkspace.rawGit(["show", spec], in: path, connection: connection)
    }

    private static func working(_ relative: String, in path: String, connection: SSHConnection?) -> Data? {
        if let connection {
            let full = (path as NSString).appendingPathComponent(relative)
            let result = SSHClient.run(connection, remoteCommand: ["cat", "--", full])
            return result.ok ? Data(result.stdout.utf8) : nil
        }
        return FileManager.default.contents(atPath: (path as NSString).appendingPathComponent(relative))
    }

    private static func isBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    private static func string(_ data: Data?) -> String {
        data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
