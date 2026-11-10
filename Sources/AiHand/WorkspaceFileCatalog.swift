import Foundation

struct WorkspaceFileEntry: Identifiable, Equatable, Hashable {
    var id: String { path }
    /// Workspace-relative path using `/` separators.
    let path: String
    let isDirectory: Bool

    var name: String {
        (path as NSString).lastPathComponent
    }

    var parentPath: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }
}

enum WorkspaceFileCatalog {
    private struct CacheKey: Hashable {
        var connectionKey: String
        var workspace: String
    }

    private static var cache: [CacheKey: (entries: [WorkspaceFileEntry], at: Date)] = [:]
    private static let lock = NSLock()
    private static let cacheTTL: TimeInterval = 30
    private static let maxEntries = 6_000
    private static let matchLimit = 8

    private static let skipDirNames: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData",
        "Pods", ".next", "dist", "vendor", ".turbo", ".cache",
        "xcuserdata", "__pycache__", ".venv", "venv"
    ]

    static func entries(
        workspace: String?,
        connectionID: UUID? = Preferences.agentWorkspaceConnectionID,
        forceRefresh: Bool = false
    ) -> [WorkspaceFileEntry] {
        let ws = workspace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !ws.isEmpty else { return [] }
        let key = CacheKey(
            connectionKey: connectionID?.uuidString ?? "local",
            workspace: ws
        )
        if !forceRefresh {
            lock.lock()
            let hit = cache[key]
            lock.unlock()
            if let hit, Date().timeIntervalSince(hit.at) < cacheTTL {
                return hit.entries
            }
        }

        let list: [WorkspaceFileEntry]
        if let connectionID {
            if let connection = Preferences.sshConnection(id: connectionID) {
                list = scanRemote(connection: connection, workspace: ws)
            } else {
                list = []
            }
        } else {
            list = scanLocal(workspace: ws)
        }

        lock.lock()
        cache[key] = (list, Date())
        lock.unlock()
        return list
    }

    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// Active `@` token, e.g. `look at @Src/Fo` → query `Src/Fo`.
    static func atQuery(in text: String) -> (query: String, range: Range<String.Index>)? {
        // Walk backward so `@` inside a `⟦file:…⟧` chip token is ignored.
        var i = text.endIndex
        while i > text.startIndex {
            i = text.index(before: i)
            guard text[i] == "@" else { continue }
            if isInsideChipToken(at: i, in: text) { continue }
            if i > text.startIndex {
                let before = text[text.index(before: i)]
                // Allow `@` after whitespace or a chip token (`⟧`).
                if before != " ", before != "\n", before != "\t", before != "⟧",
                   before != "\u{FFFC}" {
                    return nil
                }
            }
            let after = text.index(after: i)
            let rest = text[after...]
            if rest.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
                return nil
            }
            let query = String(rest)
            if query.contains(where: { ch in
                !(ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." || ch == "/" || ch == "+")
            }) {
                return nil
            }
            return (query, i..<text.endIndex)
        }
        return nil
    }

    private static func isInsideChipToken(at atIndex: String.Index, in text: String) -> Bool {
        var open: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "⟦" { open = i }
            else if text[i] == "⟧" { open = nil }
            if i == atIndex {
                return open != nil
            }
            i = text.index(after: i)
        }
        return false
    }

    static func matches(query: String, in entries: [WorkspaceFileEntry], limit: Int = matchLimit) -> [WorkspaceFileEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            // Prefer shallow / short paths when just typing `@`.
            return Array(
                entries
                    .sorted { lhs, rhs in
                        let ld = lhs.path.filter { $0 == "/" }.count
                        let rd = rhs.path.filter { $0 == "/" }.count
                        if ld != rd { return ld < rd }
                        return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
                    }
                    .prefix(limit)
            )
        }

        var exact: [WorkspaceFileEntry] = []
        var namePrefix: [WorkspaceFileEntry] = []
        var pathPrefix: [WorkspaceFileEntry] = []
        var nameContains: [WorkspaceFileEntry] = []
        var pathContains: [WorkspaceFileEntry] = []

        for entry in entries {
            let path = entry.path.lowercased()
            let name = entry.name.lowercased()
            if name == q || path == q {
                exact.append(entry)
            } else if name.hasPrefix(q) {
                namePrefix.append(entry)
            } else if path.hasPrefix(q) {
                pathPrefix.append(entry)
            } else if name.contains(q) {
                nameContains.append(entry)
            } else if path.contains(q) {
                pathContains.append(entry)
            }
        }

        var out: [WorkspaceFileEntry] = []
        out.reserveCapacity(limit)
        for bucket in [exact, namePrefix, pathPrefix, nameContains, pathContains] {
            for entry in bucket {
                if out.contains(entry) { continue }
                out.append(entry)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    // MARK: - Local

    private static func scanLocal(workspace: String) -> [WorkspaceFileEntry] {
        let root = (workspace as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        if let git = gitLsFiles(root: root) {
            return finalize(git)
        }
        return finalize(walkFiles(root: root))
    }

    private static func gitLsFiles(root: String) -> [WorkspaceFileEntry]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return [] }
        let raw = String(data: data, encoding: .utf8) ?? ""
        var files: [WorkspaceFileEntry] = []
        files.reserveCapacity(min(maxEntries, 1_024))
        for part in raw.split(separator: "\0", omittingEmptySubsequences: true) {
            let path = normalizeRelative(String(part))
            guard !path.isEmpty else { continue }
            files.append(WorkspaceFileEntry(path: path, isDirectory: false))
            if files.count >= maxEntries { break }
        }
        return files
    }

    private static func walkFiles(root: String) -> [WorkspaceFileEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [WorkspaceFileEntry] = []
        files.reserveCapacity(512)
        let rootURL = URL(fileURLWithPath: root)

        while let item = enumerator.nextObject() as? URL {
            let name = item.lastPathComponent
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let isDirectory = values?.isDirectory == true
            if isDirectory, skipDirNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            // Cap depth to keep cold non-git folders usable.
            let rel = item.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            if rel.filter({ $0 == "/" }).count > 8 {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let path = normalizeRelative(rel)
            guard !path.isEmpty else { continue }
            files.append(WorkspaceFileEntry(path: path, isDirectory: false))
            if files.count >= maxEntries { break }
        }
        return files
    }

    // MARK: - Remote

    private static func scanRemote(connection: SSHConnection, workspace: String) -> [WorkspaceFileEntry] {
        let ws = SSHClient.shellEscape(workspace)
        // Prefer git (respects ignore); fall back to a depth-capped find.
        let script = """
        cd \(ws) || exit 0
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          git ls-files -z --cached --others --exclude-standard | head -c 2000000
          exit 0
        fi
        find . -maxdepth 8 \\( \\
          -name .git -o -name node_modules -o -name .build -o -name build -o -name DerivedData \\
          -o -name Pods -o -name .next -o -name dist -o -name vendor -o -name .turbo -o -name .cache \\
          -o -name __pycache__ -o -name .venv -o -name venv \\
        \\) -prune -o -type f -print 2>/dev/null | sed 's|^\\./||' | head -n \(maxEntries) | tr '\\n' '\\0'
        """
        let result = SSHClient.runShellFast(connection, script)
        guard result.ok, !result.stdout.isEmpty else { return [] }
        var files: [WorkspaceFileEntry] = []
        files.reserveCapacity(min(maxEntries, 1_024))
        for part in result.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            let path = normalizeRelative(String(part))
            guard !path.isEmpty else { continue }
            files.append(WorkspaceFileEntry(path: path, isDirectory: false))
            if files.count >= maxEntries { break }
        }
        return finalize(files)
    }

    // MARK: - Shared

    /// Add unique parent folders so `@` can reference directories too.
    private static func finalize(_ files: [WorkspaceFileEntry]) -> [WorkspaceFileEntry] {
        var byPath: [String: WorkspaceFileEntry] = [:]
        byPath.reserveCapacity(files.count * 2)
        for file in files {
            let path = normalizeRelative(file.path)
            guard !path.isEmpty else { continue }
            byPath[path] = WorkspaceFileEntry(path: path, isDirectory: false)
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." {
                let dir = normalizeRelative(parent)
                if byPath[dir] == nil {
                    byPath[dir] = WorkspaceFileEntry(path: dir, isDirectory: true)
                }
                let next = (dir as NSString).deletingLastPathComponent
                if next == dir { break }
                parent = next
            }
            if byPath.count >= maxEntries * 2 { break }
        }
        return byPath.values.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private static func normalizeRelative(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        while p.hasPrefix("/") { p = String(p.dropFirst()) }
        if p == "." { return "" }
        return p.replacingOccurrences(of: "\\", with: "/")
    }
}
