import Foundation

struct AgentSkill: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let description: String
    let directoryName: String
    /// AiHand-provided slash command (not a scanned `SKILL.md`). Built-ins win on name collisions.
    var isBuiltIn: Bool = false
    /// SF Symbol for chips / suggestion rows; nil → default skill sparkles.
    var symbolName: String? = nil
}

/// Composer slash commands that aren't discovered from skill folders.
enum BuiltInSkills {
    static let plan = AgentSkill(
        name: "plan",
        description: "Generate an implementation plan",
        directoryName: "plan",
        isBuiltIn: true,
        symbolName: "list.bullet.clipboard"
    )

    /// Order here is the order they appear at the top of `/` suggestions.
    static let all: [AgentSkill] = [plan]

    static func skill(named name: String) -> AgentSkill? {
        let key = name.lowercased()
        return all.first { $0.name.lowercased() == key }
    }

    /// Chip / autocomplete icon for a skill name (built-in custom, else nil).
    static func symbolName(forSkillNamed name: String) -> String? {
        skill(named: name)?.symbolName
    }
}

enum SkillCatalog {
    private struct CacheKey: Hashable {
        var connectionKey: String
        var workspace: String
        var cli: AgentCLIKind
    }

    /// Per-(machine, workspace, CLI) cache so flipping between folders / CLIs doesn't rescan over SSH.
    /// Touched from main and background threads — always under `lock`.
    private static var cache: [CacheKey: (skills: [AgentSkill], at: Date)] = [:]
    private static let lock = NSLock()
    private static let cacheTTL: TimeInterval = 30

    /// Tests point this at a temp home so they never scan the real `~/.codex` / plugins trees.
    static var homeDirectoryOverride: URL?

    static func skills(
        workspace: String? = nil,
        connectionID: UUID? = Preferences.agentWorkspaceConnectionID,
        cli: AgentCLIKind = Preferences.agentCLI(for: Preferences.runtimeAgentTarget),
        forceRefresh: Bool = false
    ) -> [AgentSkill] {
        let key = CacheKey(
            connectionKey: connectionID?.uuidString ?? "local",
            workspace: workspace ?? "",
            cli: cli
        )
        if !forceRefresh {
            lock.lock()
            let hit = cache[key]
            lock.unlock()
            if let hit, Date().timeIntervalSince(hit.at) < cacheTTL {
                return hit.skills
            }
        }
        let scanned: [AgentSkill]
        if let connectionID {
            // Missing connection must not fall through to local scan of a remote path.
            if let connection = Preferences.sshConnection(id: connectionID) {
                scanned = scanRemote(connection: connection, workspace: workspace, cli: cli)
            } else {
                scanned = []
            }
        } else {
            scanned = scanLocal(workspace: workspace, cli: cli)
        }
        let list = mergeBuiltIns(over: scanned)
        lock.lock()
        cache[key] = (list, Date())
        lock.unlock()
        return list
    }

    /// Built-ins first; drop any scanned skill whose name collides (case-insensitive).
    static func mergeBuiltIns(over scanned: [AgentSkill]) -> [AgentSkill] {
        let builtIns = BuiltInSkills.all
        let reserved = Set(builtIns.map { $0.name.lowercased() })
        let rest = scanned.filter { !reserved.contains($0.name.lowercased()) }
        return builtIns + rest
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
    /// Only the selected CLI’s dirs are included (plus shared `~/.agents/skills`).
    /// First root wins when names collide (personal before plugins).
    static func skillContainerRoots(
        workspace: String?,
        cli: AgentCLIKind = Preferences.agentCLI(for: Preferences.runtimeAgentTarget)
    ) -> [URL] {
        let home = homeDirectory
        var roots: [URL] = [
            // Shared cross-agent personal / repo skills (industry `agents` layout).
            home.appendingPathComponent(".agents/skills"),
        ]
        if let workspace, !workspace.isEmpty {
            let base = URL(fileURLWithPath: workspace, isDirectory: true)
            roots.append(base.appendingPathComponent(".agents/skills"))
            switch cli {
            case .cursor:
                roots.append(base.appendingPathComponent(".cursor/skills"))
            case .claude:
                roots.append(base.appendingPathComponent(".claude/skills"))
            case .codex:
                roots.append(base.appendingPathComponent(".codex/skills"))
                roots.append(base.appendingPathComponent(".codex/skills/.system"))
            }
        }
        switch cli {
        case .cursor:
            roots.append(home.appendingPathComponent(".cursor/skills"))
            roots.append(home.appendingPathComponent(".cursor/skills-cursor"))
        case .claude:
            roots.append(home.appendingPathComponent(".claude/skills"))
        case .codex:
            roots.append(home.appendingPathComponent(".codex/skills"))
            roots.append(home.appendingPathComponent(".codex/skills/.system"))
        }
        // Installed plugins for this CLI only — lowest priority.
        for tree in pluginSkillTrees(home: home, cli: cli) {
            roots.append(contentsOf: discoverPluginSkillContainers(under: tree))
        }
        return roots
    }

    static func pluginSkillTrees(
        home: URL,
        cli: AgentCLIKind = Preferences.agentCLI(for: Preferences.runtimeAgentTarget)
    ) -> [URL] {
        switch cli {
        case .cursor:
            return [home.appendingPathComponent(".cursor/plugins")]
        case .claude:
            return [home.appendingPathComponent(".claude/plugins")]
        case .codex:
            return [
                home.appendingPathComponent(".codex/plugins"),
                home.appendingPathComponent(".codex/.tmp/plugins"),
            ]
        }
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

    private static func scanLocal(workspace: String?, cli: AgentCLIKind) -> [AgentSkill] {
        var byName: [String: AgentSkill] = [:]
        for root in skillContainerRoots(workspace: workspace, cli: cli) {
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

    private static func scanRemote(
        connection: SSHConnection,
        workspace: String?,
        cli: AgentCLIKind
    ) -> [AgentSkill] {
        // Highest priority first (first skill name wins). `$HOME` expands remotely, so the whole
        // scan is ONE ssh round-trip instead of 1 (home) + 1 per root.
        // Only the selected CLI’s dirs (+ shared `.agents/skills`) — same as local.
        var roots = ["\"$HOME/.agents/skills\""]
        if let workspace, !workspace.isEmpty {
            let ws = SSHClient.shellEscape(workspace)
            roots.append("\(ws)/.agents/skills")
            switch cli {
            case .cursor:
                roots.append("\(ws)/.cursor/skills")
            case .claude:
                roots.append("\(ws)/.claude/skills")
            case .codex:
                roots.append("\(ws)/.codex/skills")
                roots.append("\(ws)/.codex/skills/.system")
            }
        }
        switch cli {
        case .cursor:
            roots.append("\"$HOME/.cursor/skills\"")
            roots.append("\"$HOME/.cursor/skills-cursor\"")
        case .claude:
            roots.append("\"$HOME/.claude/skills\"")
        case .codex:
            roots.append("\"$HOME/.codex/skills\"")
            roots.append("\"$HOME/.codex/skills/.system\"")
        }

        let pluginTrees: [String]
        switch cli {
        case .cursor:
            pluginTrees = ["\"$HOME/.cursor/plugins\""]
        case .claude:
            pluginTrees = ["\"$HOME/.claude/plugins\""]
        case .codex:
            pluginTrees = [
                "\"$HOME/.codex/plugins\"",
                "\"$HOME/.codex/.tmp/plugins\""
            ]
        }

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
