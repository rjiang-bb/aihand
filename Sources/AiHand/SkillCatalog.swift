import Foundation

struct AgentSkill: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let description: String
    let directoryName: String
}

enum SkillCatalog {
    private struct CacheKey: Hashable {
        var connectionKey: String
        var workspace: String
    }

    private static var cached: [AgentSkill]?
    private static var cachedKey: CacheKey?
    private static var cachedAt: Date?
    private static let cacheTTL: TimeInterval = 30

    static func skills(
        workspace: String? = nil,
        connectionID: UUID? = Preferences.agentWorkspaceConnectionID,
        forceRefresh: Bool = false
    ) -> [AgentSkill] {
        let key = CacheKey(
            connectionKey: connectionID?.uuidString ?? "local",
            workspace: workspace ?? ""
        )
        if !forceRefresh,
           let cached,
           cachedKey == key,
           let cachedAt,
           Date().timeIntervalSince(cachedAt) < cacheTTL {
            return cached
        }
        let list: [AgentSkill]
        if let connectionID {
            // Missing connection must not fall through to local scan of a remote path.
            guard let connection = Preferences.sshConnection(id: connectionID) else {
                cached = []
                cachedKey = key
                cachedAt = Date()
                return []
            }
            list = scanRemote(connection: connection, workspace: workspace)
        } else {
            list = scanLocal(workspace: workspace)
        }
        cached = list
        cachedKey = key
        cachedAt = Date()
        return list
    }

    static func invalidate() {
        cached = nil
        cachedKey = nil
        cachedAt = nil
    }

    /// Slash token currently being typed, e.g. draft `hello /com` → `com`.
    static func slashQuery(in text: String) -> (query: String, range: Range<String.Index>)? {
        guard let slash = text.lastIndex(of: "/") else { return nil }
        if slash > text.startIndex {
            let before = text[text.index(before: slash)]
            if before != " " && before != "\n" && before != "\t" { return nil }
        }
        let after = text.index(after: slash)
        let rest = text[after...]
        if let space = rest.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            // Already completed a token — no active query.
            if space != rest.startIndex { return nil }
            return nil
        }
        // Allow letters, digits, dash, underscore in the skill name prefix.
        let query = String(rest)
        if query.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            return nil
        }
        return (query, slash..<text.endIndex)
    }

    static func matches(query: String, in skills: [AgentSkill], limit: Int = 8) -> [AgentSkill] {
        let q = query.lowercased()
        if q.isEmpty {
            return Array(skills.prefix(limit))
        }
        let ranked = skills.compactMap { skill -> (AgentSkill, Int)? in
            let name = skill.name.lowercased()
            if name == q { return (skill, 0) }
            if name.hasPrefix(q) { return (skill, 1) }
            if name.contains(q) { return (skill, 2) }
            if skill.description.lowercased().contains(q) { return (skill, 3) }
            return nil
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        return ranked.prefix(limit).map(\.0)
    }

    // MARK: - Local scan

    private static func scanLocal(workspace: String?) -> [AgentSkill] {
        var roots: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".cursor/skills"))
        roots.append(home.appendingPathComponent(".agents/skills"))
        roots.append(home.appendingPathComponent(".cursor/skills-cursor"))
        if let workspace, !workspace.isEmpty {
            roots.append(URL(fileURLWithPath: workspace).appendingPathComponent(".cursor/skills"))
            roots.append(URL(fileURLWithPath: workspace).appendingPathComponent(".agents/skills"))
        }

        var byName: [String: AgentSkill] = [:]
        for root in roots {
            for skill in loadSkillsLocal(in: root) {
                if byName[skill.name] == nil {
                    byName[skill.name] = skill
                }
            }
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func loadSkillsLocal(in root: URL) -> [AgentSkill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var skills: [AgentSkill] = []
        for dir in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let skillFile = dir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile.path),
                  let text = try? String(contentsOf: skillFile, encoding: .utf8),
                  let parsed = parseFrontmatter(text) else { continue }
            let name = parsed.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = (name?.isEmpty == false ? name! : dir.lastPathComponent)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !resolvedName.isEmpty else { continue }
            let description = collapseDescription(parsed.description ?? "")
            skills.append(AgentSkill(
                name: resolvedName,
                description: description,
                directoryName: dir.lastPathComponent
            ))
        }
        return skills
    }

    // MARK: - Remote scan

    private static func scanRemote(connection: SSHConnection, workspace: String?) -> [AgentSkill] {
        guard let home = SSHClient.remoteHome(connection) else { return [] }
        var roots = [
            "\(home)/.cursor/skills",
            "\(home)/.agents/skills",
            "\(home)/.cursor/skills-cursor"
        ]
        if let workspace, !workspace.isEmpty {
            roots.append("\(workspace)/.cursor/skills")
            roots.append("\(workspace)/.agents/skills")
        }

        var byName: [String: AgentSkill] = [:]
        for root in roots {
            for skill in loadSkillsRemote(connection: connection, root: root) {
                if byName[skill.name] == nil {
                    byName[skill.name] = skill
                }
            }
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func loadSkillsRemote(connection: SSHConnection, root: String) -> [AgentSkill] {
        let escaped = SSHClient.shellEscape(root)
        // Emit: dirname\0frontmatter-ish first 8KB of SKILL.md separated by records.
        let script = """
        root=\(escaped)
        [ -d "$root" ] || exit 0
        for d in "$root"/*/; do
          [ -d "$d" ] || continue
          f="${d}SKILL.md"
          [ -f "$f" ] || continue
          name=$(basename "$d")
          printf '%s\\0' "$name"
          head -c 16000 "$f"
          printf '\\0\\0'
        done
        """
        let result = SSHClient.runShell(connection, script)
        guard result.ok, !result.stdout.isEmpty else { return [] }

        var skills: [AgentSkill] = []
        let parts = result.stdout.components(separatedBy: "\0\0")
        for part in parts {
            guard !part.isEmpty else { continue }
            let pieces = part.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let directoryName = String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = String(pieces[1])
            guard !directoryName.isEmpty,
                  let parsed = parseFrontmatter(text) else { continue }
            let name = parsed.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = (name?.isEmpty == false ? name! : directoryName)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !resolvedName.isEmpty else { continue }
            skills.append(AgentSkill(
                name: resolvedName,
                description: collapseDescription(parsed.description ?? ""),
                directoryName: directoryName
            ))
        }
        return skills
    }

    private static func parseFrontmatter(_ text: String) -> (name: String?, description: String?)? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let afterOpen = normalized.dropFirst(4)
        guard let endRange = afterOpen.range(of: "\n---") else { return nil }
        let block = String(afterOpen[..<endRange.lowerBound])
        return (yamlScalar(block, key: "name"), yamlScalar(block, key: "description"))
    }

    /// Minimal YAML scalar reader for `key: value` / `key: >-` / `key: |` blocks.
    private static func yamlScalar(_ block: String, key: String) -> String? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) else { return nil }
        let line = lines[start]
        let afterKey = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if afterKey == ">" || afterKey == ">|" || afterKey == ">-" || afterKey == "|" || afterKey == "|-" || afterKey.isEmpty {
            var collected: [String] = []
            var i = start + 1
            while i < lines.count {
                let l = lines[i]
                if l.hasPrefix(" ") || l.hasPrefix("\t") || l.isEmpty {
                    collected.append(l.trimmingCharacters(in: .whitespaces))
                    i += 1
                    continue
                }
                if l.contains(":") { break }
                collected.append(l)
                i += 1
            }
            let joined = collected.filter { !$0.isEmpty }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return afterKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func collapseDescription(_ raw: String) -> String {
        let oneLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 96 { return oneLine }
        let idx = oneLine.index(oneLine.startIndex, offsetBy: 93)
        return String(oneLine[..<idx]) + "…"
    }
}
