import Foundation

/// A discovered model the chosen CLI can run (flat id — used for Claude/Codex lists).
struct AgentModelOption: Identifiable, Equatable, Hashable {
    let modelId: String
    let title: String
    var id: String { modelId }
}

/// Base model shown in the first dropdown (effort variants hang off it).
struct AgentModelFamily: Identifiable, Equatable {
    let id: String
    let title: String
    let variants: [AgentModelVariant]
}

/// Effort / speed choice for a family — maps to a concrete CLI model id (+ optional flag).
struct AgentModelVariant: Identifiable, Equatable {
    let id: String
    let title: String
    /// Value for `--model` / `-m`.
    let modelId: String
    /// Separate `--effort` / reasoning-effort when the CLI takes one.
    let effort: String?
}

enum AgentEffortLevel: String, CaseIterable, Identifiable, Codable {
    case low, medium, high, xhigh, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Max"
        }
    }
}

/// Named model (+ optional effort) preset for a specific CLI.
struct AgentFavorite: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var cliKind: AgentCLIKind
    var modelId: String
    /// Display name captured when the favorite was saved (often includes effort).
    var modelTitle: String
    /// Separate effort flag when the CLI supports it (Claude / Codex).
    var effort: String?
    /// Built-in "Default" favorite — always present, not removable when alone.
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        title: String,
        cliKind: AgentCLIKind,
        modelId: String,
        modelTitle: String,
        effort: String? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.title = title
        self.cliKind = cliKind
        self.modelId = modelId
        self.modelTitle = modelTitle
        self.effort = effort
        self.isBuiltIn = isBuiltIn
    }

    enum CodingKeys: String, CodingKey {
        case id, title, cliKind, modelId, modelTitle, effort, isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        cliKind = try c.decode(AgentCLIKind.self, forKey: .cliKind)
        modelId = try c.decode(String.self, forKey: .modelId)
        modelTitle = try c.decode(String.self, forKey: .modelTitle)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    /// Empty `modelId` means “don’t pass --model” (CLI default).
    var usesCLIDefaultModel: Bool {
        modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var detail: String {
        if usesCLIDefaultModel {
            return modelTitle.isEmpty ? cliKind.defaultModelTitle : modelTitle
        }
        var parts = [modelTitle.isEmpty ? modelId : modelTitle]
        if let effort, !effort.isEmpty,
           let level = AgentEffortLevel(rawValue: effort) {
            if !modelTitle.localizedCaseInsensitiveContains(level.title) {
                parts.append(level.title)
            }
        } else if let effort, !effort.isEmpty,
                  !modelTitle.localizedCaseInsensitiveContains(effort) {
            parts.append(effort)
        }
        return parts.joined(separator: " · ")
    }

    /// Stable Default favorite for a CLI (same id across launches).
    static func builtInDefault(for kind: AgentCLIKind) -> AgentFavorite {
        AgentFavorite(
            id: kind.defaultFavoriteID,
            title: "Default",
            cliKind: kind,
            modelId: "",
            modelTitle: kind.defaultModelTitle,
            effort: nil,
            isBuiltIn: true
        )
    }
}

/// Discovers model ids the installed CLI can accept, grouped into model + effort.
enum AgentModelCatalog {
    private struct CacheKey: Hashable {
        var kind: AgentCLIKind
        var targetKey: String
    }

    private static var cache: [CacheKey: (at: Date, families: [AgentModelFamily])] = [:]
    private static let cacheTTL: TimeInterval = 60

    private static let effortTokens: Set<String> = [
        "none", "minimal", "low", "medium", "high", "xhigh", "max"
    ]

    static func families(
        for kind: AgentCLIKind,
        forceRefresh: Bool = false,
        target: AgentExecutionTarget = Preferences.agentSettingsTarget
    ) -> [AgentModelFamily] {
        let key = CacheKey(kind: kind, targetKey: target.storageKey)
        if !forceRefresh,
           let hit = cache[key],
           Date().timeIntervalSince(hit.at) < cacheTTL {
            return hit.families
        }
        let list = discoverFamilies(kind, target: target)
        cache[key] = (Date(), list)
        return list
    }

    /// Flat list kept for callers that only need ids.
    static func models(
        for kind: AgentCLIKind,
        forceRefresh: Bool = false,
        target: AgentExecutionTarget = Preferences.agentSettingsTarget
    ) -> [AgentModelOption] {
        families(for: kind, forceRefresh: forceRefresh, target: target).flatMap { family in
            family.variants.map {
                AgentModelOption(modelId: $0.modelId, title: "\(family.title) · \($0.title)")
            }
        }
    }

    static func invalidate(_ kind: AgentCLIKind? = nil) {
        if let kind {
            for key in cache.keys where key.kind == kind {
                cache[key] = nil
            }
        } else {
            cache.removeAll()
        }
    }

    /// Claude / Codex take a separate effort flag; Cursor encodes it in the model id.
    static func usesSeparateEffortFlag(_ kind: AgentCLIKind) -> Bool {
        switch kind {
        case .cursor: return false
        case .claude, .codex: return true
        }
    }

    private static func discoverFamilies(_ kind: AgentCLIKind, target: AgentExecutionTarget) -> [AgentModelFamily] {
        switch kind {
        case .cursor: return groupCursor(discoverCursorFlat(target: target))
        case .claude: return familiesWithEffortFlag(discoverClaudeFlat())
        case .codex: return discoverCodexFamilies(target: target)
        }
    }

    // MARK: - Cursor (effort baked into model id)

    private static func discoverCursorFlat(target: AgentExecutionTarget) -> [AgentModelOption] {
        let output: String
        switch target {
        case .local:
            let exe = AgentPathLookup.resolve("agent") ?? "agent"
            output = runLocal(exe, ["--list-models"])
                ?? runLocal(exe, ["models"])
                ?? ""
        case .ssh(let id):
            guard let conn = Preferences.sshConnection(id: id),
                  let exe = SSHClient.which(conn, "agent") else {
                return cursorFallback
            }
            output = runRemote(conn, exe, ["--list-models"])
                ?? runRemote(conn, exe, ["models"])
                ?? ""
        }
        let parsed = parseIdTitleList(output)
        return parsed.isEmpty ? cursorFallback : parsed
    }

    private static func groupCursor(_ options: [AgentModelOption]) -> [AgentModelFamily] {
        var order: [String] = []
        var buckets: [String: (title: String, variants: [AgentModelVariant])] = [:]

        for option in options {
            let split = splitCursorModel(option)
            if buckets[split.baseKey] == nil {
                order.append(split.baseKey)
                buckets[split.baseKey] = (split.baseTitle, [])
            }
            var bucket = buckets[split.baseKey]!
            if !bucket.variants.contains(where: { $0.modelId == option.modelId }) {
                bucket.variants.append(
                    AgentModelVariant(
                        id: option.modelId,
                        title: split.effortTitle,
                        modelId: option.modelId,
                        effort: nil
                    )
                )
                buckets[split.baseKey] = bucket
            }
        }

        let families = order.compactMap { key -> AgentModelFamily? in
            guard var bucket = buckets[key] else { return nil }
            bucket.variants.sort { variantSortKey($0) < variantSortKey($1) }
            return AgentModelFamily(id: key, title: bucket.title, variants: bucket.variants)
        }
        return sortFamiliesByRecency(families)
    }

    /// Newest-looking families first. No release dates from the CLI — score from version
    /// tokens in the id (`grok-4.7`, `claude-opus-5-5` → 5.5, `gpt-5.6-sol`).
    private static func sortFamiliesByRecency(_ families: [AgentModelFamily]) -> [AgentModelFamily] {
        families.sorted { a, b in
            let sa = recencySortKey(id: a.id, title: a.title)
            let sb = recencySortKey(id: b.id, title: b.title)
            if sa.tier != sb.tier { return sa.tier < sb.tier }
            if sa.version != sb.version { return sa.version > sb.version }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// tier 0 = auto, 1 = composer, 2 = everything else (sorted by version desc).
    private static func recencySortKey(id: String, title: String) -> (tier: Int, version: Double) {
        let lower = id.lowercased()
        if lower == "auto" || lower.hasPrefix("auto-") {
            return (0, 1_000)
        }
        if lower.hasPrefix("composer") {
            return (1, maxVersion(in: id) ?? maxVersion(in: title) ?? 0)
        }
        let version = maxVersion(in: id) ?? maxVersion(in: title) ?? 0
        return (2, version)
    }

    /// Best version-like number found in a model id or title.
    private static func maxVersion(in text: String) -> Double? {
        let lower = text.lowercased()
        var best: Double?
        func consider(_ value: Double) {
            if best == nil || value > best! { best = value }
        }

        // `opus-5-5`, `opus-4-8` → 5.5 / 4.8 (Anthropic-style dotted minors as hyphen pairs).
        let chars = Array(lower)
        var i = 0
        while i < chars.count {
            if chars[i].isNumber {
                let start = i
                while i < chars.count && chars[i].isNumber { i += 1 }
                let major = Double(String(chars[start..<i])) ?? 0
                if i < chars.count && chars[i] == "." {
                    i += 1
                    let fracStart = i
                    while i < chars.count && chars[i].isNumber { i += 1 }
                    if i > fracStart, let frac = Double(String(chars[fracStart..<i])) {
                        let places = i - fracStart
                        consider(major + frac / pow(10, Double(places)))
                    } else {
                        consider(major)
                    }
                } else if i < chars.count && chars[i] == "-",
                          i + 1 < chars.count && chars[i + 1].isNumber {
                    // Hyphen minor only when the next run is a short digit group (e.g. 5-5, 4-8).
                    i += 1
                    let fracStart = i
                    while i < chars.count && chars[i].isNumber { i += 1 }
                    let fracStr = String(chars[fracStart..<i])
                    if fracStr.count <= 2, let frac = Double(fracStr) {
                        consider(major + frac / pow(10, Double(fracStr.count)))
                    } else {
                        consider(major)
                        // Rewind so the next loop can parse the second number as its own major.
                        i = fracStart
                    }
                } else {
                    consider(major)
                }
            } else {
                i += 1
            }
        }
        return best
    }

    private static func splitCursorModel(_ option: AgentModelOption) -> (baseKey: String, baseTitle: String, effortTitle: String) {
        var parts = option.modelId.split(separator: "-").map(String.init)
        var fast = false
        if parts.last?.lowercased() == "fast" {
            fast = true
            parts.removeLast()
        }
        var effortToken: String?
        if let last = parts.last?.lowercased(), effortTokens.contains(last) {
            effortToken = last
            parts.removeLast()
        }
        let baseKey = parts.isEmpty ? option.modelId : parts.joined(separator: "-")
        let baseTitle = stripEffortFromTitle(option.title)
        let effortTitle: String
        if let effortToken {
            let name = effortLabel(effortToken)
            effortTitle = fast ? "\(name) Fast" : name
        } else if fast {
            effortTitle = "Fast"
        } else {
            effortTitle = "Default"
        }
        return (baseKey, baseTitle.isEmpty ? baseKey : baseTitle, effortTitle)
    }

    private static func stripEffortFromTitle(_ title: String) -> String {
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Longest phrases first so "Extra High" wins over "High".
        let suffixes = [
            " Extra High Fast", " Extra High", " High Fast", " High",
            " Medium Fast", " Medium", " Low Fast", " Low",
            " Max Fast", " Max", " Minimal Fast", " Minimal",
            " None Fast", " None", " Fast"
        ]
        for suffix in suffixes {
            if result.hasSuffix(suffix) || result.lowercased().hasSuffix(suffix.lowercased()) {
                result = String(result.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        // Collapse leftover double spaces (e.g. "Grok 4.7  ").
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func effortLabel(_ token: String) -> String {
        switch token.lowercased() {
        case "xhigh": return "Extra High"
        case "none": return "None"
        case "minimal": return "Minimal"
        case "ultra": return "Ultra"
        default:
            return AgentEffortLevel(rawValue: token)?.title ?? token.capitalized
        }
    }

    private static func variantSortKey(_ variant: AgentModelVariant) -> String {
        let t = variant.title.lowercased()
        let rank: Int
        if t == "default" { rank = 0 }
        else if t.hasPrefix("none") { rank = 1 }
        else if t.hasPrefix("minimal") { rank = 2 }
        else if t.hasPrefix("low") { rank = 3 }
        else if t.hasPrefix("medium") { rank = 4 }
        else if t.hasPrefix("high") { rank = 5 }
        else if t.hasPrefix("extra") { rank = 6 }
        else if t.hasPrefix("max") { rank = 7 }
        else if t.hasPrefix("ultra") { rank = 8 }
        else if t == "fast" { rank = 9 }
        else { rank = 10 }
        let fast = t.contains("fast") ? 1 : 0
        return String(format: "%02d-%d-%@", rank, fast, t)
    }

    private static var cursorFallback: [AgentModelOption] {
        [
            AgentModelOption(modelId: "auto", title: "Auto"),
            AgentModelOption(modelId: "composer-2.5", title: "Composer 2.5"),
            AgentModelOption(modelId: "composer-2.5-fast", title: "Composer 2.5 Fast")
        ]
    }

    // MARK: - Claude / Codex (separate effort flag)

    private static func familiesWithEffortFlag(_ options: [AgentModelOption]) -> [AgentModelFamily] {
        let families = options.map { option -> AgentModelFamily in
            let variants = AgentEffortLevel.allCases.map { level in
                AgentModelVariant(
                    id: "\(option.modelId)|\(level.rawValue)",
                    title: level.title,
                    modelId: option.modelId,
                    effort: level.rawValue
                )
            }
            return AgentModelFamily(id: option.modelId, title: option.title, variants: variants)
        }
        return sortFamiliesByRecency(families)
    }

    private static func discoverClaudeFlat() -> [AgentModelOption] {
        [
            AgentModelOption(modelId: "sonnet", title: "Sonnet (alias)"),
            AgentModelOption(modelId: "opus", title: "Opus (alias)"),
            AgentModelOption(modelId: "fable", title: "Fable (alias)"),
            AgentModelOption(modelId: "haiku", title: "Haiku (alias)"),
            AgentModelOption(modelId: "claude-sonnet-5", title: "Claude Sonnet 5"),
            AgentModelOption(modelId: "claude-opus-5", title: "Claude Opus 5"),
            AgentModelOption(modelId: "claude-opus-5-5", title: "Claude Opus 5.5"),
            AgentModelOption(modelId: "claude-fable-5", title: "Claude Fable 5"),
            AgentModelOption(modelId: "claude-haiku-5", title: "Claude Haiku 5"),
            AgentModelOption(modelId: "claude-opus-4-8", title: "Claude Opus 4.8"),
            AgentModelOption(modelId: "claude-sonnet-4-6", title: "Claude Sonnet 4.6")
        ]
    }

    /// Live catalog from `codex debug models` (JSON). Falls back to legacy text list, then static ids.
    private static func discoverCodexFamilies(target: AgentExecutionTarget) -> [AgentModelFamily] {
        let exe: String?
        let runCmd: (String, [String]) -> String?
        switch target {
        case .local:
            exe = AgentPathLookup.resolve("codex")
            runCmd = { runLocal($0, $1) }
        case .ssh(let id):
            guard let conn = Preferences.sshConnection(id: id) else {
                return familiesWithEffortFlag(codexFallbackModels)
            }
            exe = SSHClient.which(conn, "codex")
            runCmd = { runRemote(conn, $0, $1) }
        }
        if let exe {
            if let json = runCmd(exe, ["debug", "models"]),
               let families = parseCodexDebugModels(json),
               !families.isEmpty {
                return sortFamiliesByRecency(families)
            }
            let output = runCmd(exe, ["models"]) ?? runCmd(exe, ["--list-models"]) ?? ""
            let parsed = parseIdTitleList(output)
            if !parsed.isEmpty {
                return familiesWithEffortFlag(parsed)
            }
        }
        return familiesWithEffortFlag(codexFallbackModels)
    }

    private static var codexFallbackModels: [AgentModelOption] {
        [
            AgentModelOption(modelId: "gpt-6-luna", title: "GPT-6-Luna"),
            AgentModelOption(modelId: "gpt-5.6-terra", title: "GPT-5.6-Terra"),
            AgentModelOption(modelId: "gpt-5.6-luna", title: "GPT-5.6-Luna")
        ]
    }

    /// Parses `codex debug models` JSON: `{ "models": [ { slug, visibility, supported_reasoning_levels } ] }`.
    private static func parseCodexDebugModels(_ text: String) -> [AgentModelFamily]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let data = String(trimmed[start...]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let models = root["models"] as? [[String: Any]] ?? []
        guard !models.isEmpty else { return nil }

        var families: [AgentModelFamily] = []
        var seen = Set<String>()
        for model in models {
            if let visibility = model["visibility"] as? String,
               visibility.lowercased() != "list" {
                continue
            }
            guard let slug = (model["slug"] as? String) ?? (model["id"] as? String),
                  !slug.isEmpty,
                  seen.insert(slug).inserted else {
                continue
            }
            let title = (model["display_name"] as? String)
                ?? (model["name"] as? String)
                ?? prettyCodexTitle(slug)

            let levelEntries = model["supported_reasoning_levels"] as? [[String: Any]] ?? []
            var efforts: [String] = []
            var effortSeen = Set<String>()
            for entry in levelEntries {
                guard let effort = entry["effort"] as? String,
                      !effort.isEmpty,
                      effortSeen.insert(effort).inserted else { continue }
                efforts.append(effort)
            }

            let variants: [AgentModelVariant]
            if efforts.isEmpty {
                // Catalog didn't advertise levels — keep a usable Default + common ladder.
                variants = [AgentModelVariant(id: slug, title: "Default", modelId: slug, effort: nil)]
                    + AgentEffortLevel.allCases.map { level in
                        AgentModelVariant(
                            id: "\(slug)|\(level.rawValue)",
                            title: level.title,
                            modelId: slug,
                            effort: level.rawValue
                        )
                    }
            } else {
                variants = efforts.map { effort in
                    AgentModelVariant(
                        id: "\(slug)|\(effort)",
                        title: effortLabel(effort),
                        modelId: slug,
                        effort: effort
                    )
                }
            }
            families.append(AgentModelFamily(id: slug, title: title, variants: variants))
        }
        return families.isEmpty ? nil : families
    }

    private static func prettyCodexTitle(_ slug: String) -> String {
        slug.split(separator: "-").map { part -> String in
            let s = String(part)
            if s.lowercased() == "gpt" { return "GPT" }
            if s.first?.isNumber == true { return s }
            return s.prefix(1).uppercased() + s.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    private static func parseIdTitleList(_ text: String) -> [AgentModelOption] {
        var seen = Set<String>()
        var out: [AgentModelOption] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  !line.lowercased().hasPrefix("available models") else { continue }
            guard let sep = line.range(of: " - ") else { continue }
            let id = String(line[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            out.append(AgentModelOption(modelId: id, title: title.isEmpty ? id : title))
        }
        return out
    }

    private static func runLocal(_ exe: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let out = Pipe()
        // Discard stderr — a Pipe we never drain can still deadlock on large/noisy CLIs.
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extras = ["\(home)/.local/bin", "/usr/local/bin", "/opt/homebrew/bin", "\(home)/.npm-global/bin"]
        let path = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extras + [path]).joined(separator: ":")
        process.environment = env
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before/while waiting. `codex debug models` is ~300KB; waiting first fills the
        // pipe buffer (~64KB) and deadlocks forever (Settings stuck on "Loading…").
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? nil : text
    }

    private static func runRemote(_ connection: SSHConnection, _ exe: String, _ args: [String]) -> String? {
        var remote = [exe]
        remote.append(contentsOf: args)
        let result = SSHClient.run(connection, remoteCommand: remote)
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Prefer success, but accept JSON/catalog text when Codex exits non-zero after printing.
        if result.ok || text.contains("{") || text.contains(" - ") {
            return text
        }
        return nil
    }
}
