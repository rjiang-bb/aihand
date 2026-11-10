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

    /// Per-(machine, workspace) cache so flipping between folders doesn't rescan over SSH.
    /// Touched from main and background threads — always under `lock`.
    private static var cache: [CacheKey: (skills: [AgentSkill], at: Date)] = [:]
    private static let lock = NSLock()
    private static let cacheTTL: TimeInterval = 30

    /// Tests point this at a temp home so they never scan the real `~/.codex` / plugins trees.
    static var homeDirectoryOverride: URL?

    static func skills(
        workspace: String? = nil,
        connectionID: UUID? = Preferences.agentWorkspaceConnectionID,
        forceRefresh: Bool = false
    ) -> [AgentSkill] {
        let key = CacheKey(
            connectionKey: connectionID?.uuidString ?? "local",
            workspace: workspace ?? ""
        )
        if !forceRefresh {
            lock.lock()
            let hit = cache[key]
            lock.unlock()
            if let hit, Date().timeIntervalSince(hit.at) < cacheTTL {
                return hit.skills
            }
        }
        let list: [AgentSkill]
        if let connectionID {
            // Missing connection must not fall through to local scan of a remote path.
            if let connection = Preferences.sshConnection(id: connectionID) {
                list = scanRemote(connection: connection, workspace: workspace)
            } else {
                list = []
            }
        } else {
            list = scanLocal(workspace: workspace)
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

    /// Slash token currently being typed, e.g. draft `hello /com` → `com`.
    /// Ignores `/` that sit inside serialized chips (`⟦skill:…⟧` / `⟦file:…⟧`).
    static func slashQuery(in text: String) -> (query: String, range: Range<String.Index>)? {
        guard let slash = lastActiveSlash(in: text) else { return nil }
        if slash > text.startIndex {
            let before = text[text.index(before: slash)]
            // Space / newline / chip close are valid token boundaries.
            if before != " " && before != "\n" && before != "\t" && before != "⟧" { return nil }
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

    /// Last `/` that is not inside a `⟦…⟧` chip token.
    private static func lastActiveSlash(in text: String) -> String.Index? {
        var best: String.Index?
        var i = text.startIndex
        var inChip = false
        while i < text.endIndex {
            let ch = text[i]
            if ch == "⟦" {
                inChip = true
            } else if ch == "⟧" {
                inChip = false
            } else if ch == "/", !inChip {
                best = i
            }
            i = text.index(after: i)
        }
        return best
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

    private static var homeDirectory: URL {
        homeDirectoryOverride ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Skill containers whose immediate children are `name/SKILL.md` folders.
    /// First root wins when names collide (Cursor/agents before CLI/plugin caches).
    static func skillContainerRoots(workspace: String?) -> [URL] {
        let home = homeDirectory
        var roots: [URL] = [
            home.appendingPathComponent(".cursor/skills"),
            home.appendingPathComponent(".agents/skills"),
            home.appendingPathComponent(".cursor/skills-cursor"),
        ]
        if let workspace, !workspace.isEmpty {
            let base = URL(fileURLWithPath: workspace, isDirectory: true)
            roots.append(base.appendingPathComponent(".cursor/skills"))
            roots.append(base.appendingPathComponent(".agents/skills"))
            roots.append(base.appendingPathComponent(".claude/skills"))
            roots.append(base.appendingPathComponent(".codex/skills"))
            roots.append(base.appendingPathComponent(".codex/skills/.system"))
        }
        // CLI-specific personal + bundled system skills.
        roots.append(home.appendingPathComponent(".claude/skills"))
        roots.append(home.appendingPathComponent(".codex/skills"))
        roots.append(home.appendingPathComponent(".codex/skills/.system"))
        // Installed plugins (Codex / Claude / Cursor) — lowest priority.
        for tree in pluginSkillTrees(home: home) {
            roots.append(contentsOf: discoverPluginSkillContainers(under: tree))
        }
        return roots
    }

    private static func pluginSkillTrees(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".codex/plugins"),
            home.appendingPathComponent(".codex/.tmp/plugins"),
            home.appendingPathComponent(".claude/plugins"),
            home.appendingPathComponent(".cursor/plugins"),
        ]
    }

    /// Directories named `skills`, `skills-*`, or `*-skills` that hold skill folders.
    static func discoverPluginSkillContainers(under base: URL, maxDepth: Int = 8) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: base.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        let basePath = base.path
        while let item = enumerator.nextObject() as? URL {
            let rel = item.path.dropFirst(basePath.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let depth = rel.isEmpty ? 0 : rel.split(separator: "/").count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let name = item.lastPathComponent
            let isSkillsDir = name == "skills"
                || name.hasPrefix("skills-")
                || name.hasSuffix("-skills")
            guard isSkillsDir else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
            found.append(item)
            enumerator.skipDescendants()
        }
        return found
    }

    private static func scanLocal(workspace: String?) -> [AgentSkill] {
        var byName: [String: AgentSkill] = [:]
        for root in skillContainerRoots(workspace: workspace) {
            for skill in loadSkillsLocal(in: root) where byName[skill.name] == nil {
                byName[skill.name] = skill
            }
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func loadSkillsLocal(in root: URL) -> [AgentSkill] {
        let fm = FileManager.default
        // Include hidden children when the root itself is a hidden system folder
        // (`~/.codex/skills/.system`); still skip dotfiles under normal roots.
        let options: FileManager.DirectoryEnumerationOptions =
            root.lastPathComponent.hasPrefix(".") ? [] : [.skipsHiddenFiles]
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
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
        // Highest priority first (first skill name wins). `$HOME` expands remotely, so the whole
        // scan is ONE ssh round-trip instead of 1 (home) + 1 per root.
        var roots = [
            "\"$HOME/.cursor/skills\"",
            "\"$HOME/.agents/skills\"",
            "\"$HOME/.cursor/skills-cursor\""
        ]
        if let workspace, !workspace.isEmpty {
            let ws = SSHClient.shellEscape(workspace)
            roots.append("\(ws)/.cursor/skills")
            roots.append("\(ws)/.agents/skills")
            roots.append("\(ws)/.claude/skills")
            roots.append("\(ws)/.codex/skills")
            roots.append("\(ws)/.codex/skills/.system")
        }
        roots.append(contentsOf: [
            "\"$HOME/.claude/skills\"",
            "\"$HOME/.codex/skills\"",
            "\"$HOME/.codex/skills/.system\""
        ])

        let pluginTrees = [
            "\"$HOME/.codex/plugins\"",
            "\"$HOME/.codex/.tmp/plugins\"",
            "\"$HOME/.claude/plugins\"",
            "\"$HOME/.cursor/plugins\""
        ]

        // Emit per skill: dirname\0first-16KB-of-SKILL.md\0\0, roots in priority order.
        // Plugin trees: find `skills` / `skills-*` / `*-skills` containers (depth ≤ 8).
        let script = """
        emit_root() {
          local root="$1"
          [ -d "$root" ] || return 0
          local d
          for d in "$root"/*/; do
            [ -d "$d" ] || continue
            local f="${d}SKILL.md"
            [ -f "$f" ] || continue
            printf '%s\\0' "$(basename "$d")"
            head -c 16000 "$f"
            printf '\\0\\0'
          done
        }
        for root in \(roots.joined(separator: " ")); do
          emit_root "$root"
        done
        for base in \(pluginTrees.joined(separator: " ")); do
          [ -d "$base" ] || continue
          # -name patterns cover Cursor's skills-figquery / workflow-skills too.
          while IFS= read -r root; do
            emit_root "$root"
          done < <(find "$base" -maxdepth 8 \\( -type d -name 'skills' -o -type d -name 'skills-*' -o -type d -name '*-skills' \\) 2>/dev/null)
        done
        """
        let result = SSHClient.runShellFast(connection, script)
        guard result.ok, !result.stdout.isEmpty else { return [] }

        var byName: [String: AgentSkill] = [:]
        for skill in parseRemoteSkills(result.stdout) where byName[skill.name] == nil {
            byName[skill.name] = skill
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func parseRemoteSkills(_ stdout: String) -> [AgentSkill] {
        var skills: [AgentSkill] = []
        let parts = stdout.components(separatedBy: "\0\0")
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
