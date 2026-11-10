import AppKit
import Carbon.HIToolbox
import ServiceManagement

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let toggleDefault = Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧H")
    static let clearDefault = Shortcut(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧X")
    static let sessionsDefault = Shortcut(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧G")
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` follows the macOS appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum InteractKey: String, CaseIterable {
    case option, command, control, off

    var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .off: return "Off"
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        case .off: return ""
        }
    }

    var cgFlags: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .control: return .maskControl
        case .off: return []
        }
    }
}

enum AgentCLIKind: String, CaseIterable, Identifiable, Codable {
    case cursor
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursor: return "Cursor Agent"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var commandName: String {
        switch self {
        case .cursor: return "agent"
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    var installHint: String {
        switch self {
        case .cursor: return "Install the Cursor CLI (`agent`)."
        case .claude: return "Install Claude Code (`claude`) — https://code.claude.com/docs/en/cli-reference"
        case .codex: return "Install Codex (`curl -fsSL https://chatgpt.com/codex/install.sh | sh`)."
        }
    }

    /// Shell command shown in Settings when this CLI is missing (copyable).
    var installCommand: String? {
        switch self {
        case .cursor: return nil
        case .claude: return nil
        case .codex: return "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
        }
    }

    /// Short label for the CLI’s default model when AiHand doesn’t pass `--model`.
    var defaultModelTitle: String {
        switch self {
        case .cursor: return "Auto"
        case .claude: return "Default"
        case .codex: return "Default"
        }
    }

    /// Stable UUID for the built-in Default favorite for this CLI.
    var defaultFavoriteID: UUID {
        switch self {
        case .cursor: return UUID(uuidString: "00000000-0000-4000-8000-54494E590001")!
        case .claude: return UUID(uuidString: "00000000-0000-4000-8000-54494E590002")!
        case .codex: return UUID(uuidString: "00000000-0000-4000-8000-54494E590003")!
        }
    }

    var loginHint: String {
        switch self {
        case .cursor: return "`agent login`"
        case .claude: return "`claude auth login`"
        case .codex: return "`codex` (sign in with ChatGPT)"
        }
    }
}

/// Cursor Agent permission posture for unattended AiHand runs.
enum CursorAgentPermissionMode: String, CaseIterable, Identifiable, Codable {
    case force
    case sandboxed
    case autoReview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .force: return "Force allow"
        case .sandboxed: return "Force allow (sandbox)"
        case .autoReview: return "Auto-review"
        }
    }

    var detail: String {
        switch self {
        case .force: return "Auto-approve tool calls (`--force`), unless denied by policy."
        case .sandboxed: return "Same as force allow, with the Cursor sandbox enabled."
        case .autoReview: return "Smart Auto: safe calls run; the rest need review (`--auto-review`)."
        }
    }
}

/// Claude Code permission posture for unattended AiHand runs.
enum ClaudeAgentPermissionMode: String, CaseIterable, Identifiable, Codable {
    case bypass
    case acceptEdits
    case auto
    case dontAsk
    case plan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bypass: return "Bypass permissions"
        case .acceptEdits: return "Accept edits"
        case .auto: return "Auto"
        case .dontAsk: return "Don’t ask"
        case .plan: return "Plan only"
        }
    }

    var detail: String {
        switch self {
        case .bypass: return "Skip permission checks (`--dangerously-skip-permissions`)."
        case .acceptEdits: return "Auto-approve workspace file edits; other tools may still prompt."
        case .auto: return "Background classifier screens tool calls (`--permission-mode auto`)."
        case .dontAsk: return "Auto-deny anything that would prompt (`--permission-mode dontAsk`)."
        case .plan: return "Explore and propose changes without editing (`--permission-mode plan`)."
        }
    }
}

/// Codex sandbox posture for unattended AiHand runs.
enum CodexAgentPermissionMode: String, CaseIterable, Identifiable, Codable {
    case workspaceWrite
    case readOnly
    case fullAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspaceWrite: return "Workspace write"
        case .readOnly: return "Read only"
        case .fullAccess: return "Full access"
        }
    }

    var detail: String {
        switch self {
        case .workspaceWrite: return "Edit and run commands inside the workspace (`--sandbox workspace-write`)."
        case .readOnly: return "Inspect only; no edits (`--sandbox read-only`)."
        case .fullAccess: return "No sandbox or approval prompts (`--dangerously-bypass-approvals-and-sandbox`)."
        }
    }
}

enum InkChoice: String, CaseIterable {
    case match, red, orange, yellow, green, blue, purple, white, black

    var title: String {
        switch self {
        case .match: return "Match the pointer"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .white: return "White"
        case .black: return "Black"
        }
    }

    var color: CGColor? {
        switch self {
        case .match: return nil
        case .red: return Ink.red
        case .orange: return Ink.hex(0xFF8A00)
        case .yellow: return Ink.hex(0xFFCC00)
        case .green: return Ink.hex(0x30C25A)
        case .blue: return Ink.hex(0x0A84FF)
        case .purple: return Ink.hex(0x8754F2)
        case .white: return Ink.hex(0xFFFFFF)
        case .black: return Ink.hex(0x1D1D21)
        }
    }

    func resolved(for style: PointerStyle) -> CGColor {
        color ?? style.inkColor
    }
}

enum DrawTool: String, CaseIterable {
    case freehand, rectangle, arrow, text

    var title: String {
        switch self {
        case .freehand: return "Freehand"
        case .rectangle: return "Rectangle"
        case .arrow: return "Arrow"
        case .text: return "Text"
        }
    }

    var shortcut: String {
        switch self {
        case .freehand: return "F"
        case .rectangle: return "R"
        case .arrow: return "A"
        case .text: return "T"
        }
    }

    var symbol: String {
        switch self {
        case .freehand: return "scribble"
        case .rectangle: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        }
    }
}

enum StrokeThickness: Int, CaseIterable {
    case thin = 1, light, medium, heavy, bold

    var title: String {
        switch self {
        case .thin: return "Thin"
        case .light: return "Light"
        case .medium: return "Medium"
        case .heavy: return "Heavy"
        case .bold: return "Bold"
        }
    }

    var shortcut: String { "\(rawValue)" }

    /// Multiplier on the screen-relative base ink width.
    var multiplier: CGFloat {
        switch self {
        case .thin: return 0.55
        case .light: return 0.75
        case .medium: return 1.0
        case .heavy: return 1.45
        case .bold: return 2.0
        }
    }
}

enum CaptureScope: String, CaseIterable {
    case screen, window

    var title: String {
        switch self {
        case .screen: return "Entire screen"
        case .window: return "Focused window"
        }
    }

    var shortTitle: String {
        switch self {
        case .screen: return "Screen"
        case .window: return "Window"
        }
    }

    var symbol: String {
        switch self {
        case .screen: return "rectangle.dashed"
        case .window: return "macwindow"
        }
    }

    var toggled: CaptureScope {
        self == .screen ? .window : .screen
    }
}

enum Preferences {
    static let changed = Notification.Name("AiHandPreferencesChanged")
    /// Swapped for a throwaway suite in tests.
    static var defaults = UserDefaults.standard

    static var toggleShortcut: Shortcut {
        get { loadShortcut("shortcut.toggle") ?? .toggleDefault }
        set { saveShortcut(newValue, "shortcut.toggle") }
    }

    static var clearShortcut: Shortcut {
        get { loadShortcut("shortcut.clear") ?? .clearDefault }
        set { saveShortcut(newValue, "shortcut.clear") }
    }

    static var sessionsShortcut: Shortcut {
        get { loadShortcut("shortcut.sessions") ?? .sessionsDefault }
        set { saveShortcut(newValue, "shortcut.sessions") }
    }

    /// Hand length as a fraction of screen height. Max 0.20 (= 20%); min ≈ 36pt on a typical display.
    static let pointerSizeRange: ClosedRange<CGFloat> = 0.04...0.20

    static var pointerSize: CGFloat {
        get {
            let raw = (defaults.object(forKey: "pointerSize") as? Double).map { CGFloat($0) } ?? 0.13
            return min(max(raw, pointerSizeRange.lowerBound), pointerSizeRange.upperBound)
        }
        set {
            let clamped = min(max(newValue, pointerSizeRange.lowerBound), pointerSizeRange.upperBound)
            set(Double(clamped), "pointerSize")
        }
    }

    static var showShadow: Bool {
        get { defaults.object(forKey: "showShadow") as? Bool ?? true }
        set { set(newValue, "showShadow") }
    }

    /// App chrome theme for settings, sessions, annotate prompts, etc.
    static var theme: AppTheme {
        get { defaults.string(forKey: "theme").flatMap(AppTheme.init(rawValue:)) ?? .system }
        set {
            set(newValue.rawValue, "theme")
            applyTheme()
        }
    }

    static func applyTheme() {
        NSApp.appearance = theme.nsAppearance
    }

    static var handSound: Bool {
        get { defaults.object(forKey: "sound.hands") as? Bool ?? true }
        set { set(newValue, "sound.hands") }
    }

    static var tapSound: TapSoundChoice {
        get { defaults.string(forKey: "tapSound").flatMap(TapSoundChoice.init(rawValue:)) ?? .thock }
        set { set(newValue.rawValue, "tapSound") }
    }

    static var laserSound: Bool {
        get { defaults.object(forKey: "sound.laser") as? Bool ?? false }
        set { set(newValue, "sound.laser") }
    }

    static var interactKeepsHand: Bool {
        get { defaults.bool(forKey: "interactKeepsHand") }
        set { set(newValue, "interactKeepsHand") }
    }

    static var interactKey: InteractKey {
        get { defaults.string(forKey: "interactKey").flatMap(InteractKey.init(rawValue:)) ?? .option }
        set { set(newValue.rawValue, "interactKey") }
    }

    static var inkChoice: InkChoice {
        get { defaults.string(forKey: "inkChoice").flatMap(InkChoice.init(rawValue:)) ?? .match }
        set { set(newValue.rawValue, "inkChoice") }
    }

    static var showInkButton: Bool {
        get { defaults.object(forKey: "showInkButton") as? Bool ?? true }
        set { set(newValue, "showInkButton") }
    }

    static var drawTool: DrawTool {
        get { defaults.string(forKey: "drawTool").flatMap(DrawTool.init(rawValue:)) ?? .freehand }
        set { set(newValue.rawValue, "drawTool") }
    }

    static var strokeThickness: StrokeThickness {
        get {
            let raw = defaults.object(forKey: "strokeThickness") as? Int
            return raw.flatMap(StrokeThickness.init(rawValue:)) ?? .medium
        }
        set { set(newValue.rawValue, "strokeThickness") }
    }

    /// What the annotate screenshot includes: the full display or the frontmost window.
    static var captureScope: CaptureScope {
        get { defaults.string(forKey: "captureScope").flatMap(CaptureScope.init(rawValue:)) ?? .screen }
        set { set(newValue.rawValue, "captureScope") }
    }

    // MARK: - SSH connections

    static var sshConnections: [SSHConnection] {
        get {
            guard let data = defaults.data(forKey: "sshConnections") else { return [] }
            return (try? JSONDecoder().decode([SSHConnection].self, from: data)) ?? []
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            defaults.set(data, forKey: "sshConnections")
            // Drop settings target if connection removed.
            if case .ssh(let id) = agentSettingsTarget, !newValue.contains(where: { $0.id == id }) {
                defaults.set(AgentExecutionTarget.local.storageKey, forKey: "agentSettingsTarget")
            }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func sshConnection(id: UUID) -> SSHConnection? {
        sshConnections.first { $0.id == id }
    }

    static func addSSHConnection(_ connection: SSHConnection) {
        var list = sshConnections
        list.append(connection)
        sshConnections = list
    }

    static func removeSSHConnection(_ id: UUID) {
        if let conn = sshConnection(id: id) {
            SSHClient.closeMaster(conn)
        }
        // Drop workspaces bound to this machine.
        let remaining = agentWorkspaceRefs.filter { $0.connectionID != id }
        if remaining.count != agentWorkspaceRefs.count {
            writeWorkspaceRefs(remaining)
            if let first = remaining.first {
                selectAgentWorkspaceRef(first.id)
            } else {
                defaults.removeObject(forKey: "agentWorkspaceRootID")
                defaults.removeObject(forKey: "agentWorkspace")
                defaults.removeObject(forKey: "agentWorkspaceRoot")
            }
        }
        var buckets = agentSettingsBuckets
        buckets.removeValue(forKey: id.uuidString)
        agentSettingsBuckets = buckets
        sshConnections = sshConnections.filter { $0.id != id }
    }

    // MARK: - Agent settings target (editing context)

    /// Which machine’s Agent settings are being edited (Local or an SSH connection).
    static var agentSettingsTarget: AgentExecutionTarget {
        get {
            migrateLegacyAgentSettingsIfNeeded()
            let raw = (defaults.string(forKey: "agentSettingsTarget") ?? "local")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if raw == "local" || raw.isEmpty { return .local }
            if let id = UUID(uuidString: raw), sshConnections.contains(where: { $0.id == id }) {
                return .ssh(id)
            }
            return .local
        }
        set {
            defaults.set(newValue.storageKey, forKey: "agentSettingsTarget")
            ensureAgentFavorites(for: newValue)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Target used when starting sessions — follows the Current workspace’s machine.
    static var runtimeAgentTarget: AgentExecutionTarget {
        AgentExecutionTarget(connectionID: currentWorkspaceRef?.connectionID)
    }

    private struct TargetAgentSettings: Codable {
        var agentCLI: String?
        var permissionModes: [String: String]?
        var favorites: [AgentFavorite]?
        var currentFavoriteIDs: [String: String]?
    }

    private static var agentSettingsBuckets: [String: TargetAgentSettings] {
        get {
            migrateLegacyAgentSettingsIfNeeded()
            guard let data = defaults.data(forKey: "agentSettingsByTarget") else { return [:] }
            return (try? JSONDecoder().decode([String: TargetAgentSettings].self, from: data)) ?? [:]
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            defaults.set(data, forKey: "agentSettingsByTarget")
        }
    }

    private static var didMigrateAgentSettings = false

    private static func migrateLegacyAgentSettingsIfNeeded() {
        guard !didMigrateAgentSettings else { return }
        didMigrateAgentSettings = true
        if defaults.data(forKey: "agentSettingsByTarget") != nil { return }
        var bucket = TargetAgentSettings()
        bucket.agentCLI = defaults.string(forKey: "agentCLI")
        bucket.permissionModes = defaults.dictionary(forKey: "agentPermissionModes") as? [String: String]
        if let data = defaults.data(forKey: "agentFavorites"),
           let favs = try? JSONDecoder().decode([AgentFavorite].self, from: data) {
            bucket.favorites = favs
        }
        var ids = defaults.dictionary(forKey: "currentAgentFavoriteIDs") as? [String: String] ?? [:]
        if let legacy = defaults.string(forKey: "currentAgentFavoriteID"), ids["cursor"] == nil {
            ids[AgentCLIKind.cursor.rawValue] = legacy
        }
        bucket.currentFavoriteIDs = ids.isEmpty ? nil : ids
        agentSettingsBuckets = ["local": bucket]
    }

    private static func settingsBucket(for target: AgentExecutionTarget) -> TargetAgentSettings {
        agentSettingsBuckets[target.storageKey] ?? TargetAgentSettings()
    }

    private static func updateSettingsBucket(for target: AgentExecutionTarget, _ mutate: (inout TargetAgentSettings) -> Void) {
        var buckets = agentSettingsBuckets
        var bucket = buckets[target.storageKey] ?? TargetAgentSettings()
        mutate(&bucket)
        buckets[target.storageKey] = bucket
        agentSettingsBuckets = buckets
    }

    static var agentCLI: AgentCLIKind {
        get { agentCLI(for: agentSettingsTarget) }
        set { setAgentCLI(newValue, for: agentSettingsTarget) }
    }

    static func agentCLI(for target: AgentExecutionTarget) -> AgentCLIKind {
        settingsBucket(for: target).agentCLI.flatMap(AgentCLIKind.init(rawValue:)) ?? .cursor
    }

    static func setAgentCLI(_ kind: AgentCLIKind, for target: AgentExecutionTarget) {
        updateSettingsBucket(for: target) { $0.agentCLI = kind.rawValue }
        ensureAgentFavorites(for: target)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func permissionModes(for target: AgentExecutionTarget) -> [String: String] {
        settingsBucket(for: target).permissionModes ?? [:]
    }

    private static func setPermissionMode(cli: AgentCLIKind, raw: String, target: AgentExecutionTarget) {
        updateSettingsBucket(for: target) { bucket in
            var map = bucket.permissionModes ?? [:]
            map[cli.rawValue] = raw
            bucket.permissionModes = map
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static var cursorPermissionMode: CursorAgentPermissionMode {
        get {
            permissionModes(for: agentSettingsTarget)[AgentCLIKind.cursor.rawValue]
                .flatMap(CursorAgentPermissionMode.init(rawValue:)) ?? .force
        }
        set { setPermissionMode(cli: .cursor, raw: newValue.rawValue, target: agentSettingsTarget) }
    }

    static var claudePermissionMode: ClaudeAgentPermissionMode {
        get {
            permissionModes(for: agentSettingsTarget)[AgentCLIKind.claude.rawValue]
                .flatMap(ClaudeAgentPermissionMode.init(rawValue:)) ?? .bypass
        }
        set { setPermissionMode(cli: .claude, raw: newValue.rawValue, target: agentSettingsTarget) }
    }

    static var codexPermissionMode: CodexAgentPermissionMode {
        get {
            permissionModes(for: agentSettingsTarget)[AgentCLIKind.codex.rawValue]
                .flatMap(CodexAgentPermissionMode.init(rawValue:)) ?? .workspaceWrite
        }
        set { setPermissionMode(cli: .codex, raw: newValue.rawValue, target: agentSettingsTarget) }
    }

    static func cursorPermissionMode(for target: AgentExecutionTarget) -> CursorAgentPermissionMode {
        permissionModes(for: target)[AgentCLIKind.cursor.rawValue]
            .flatMap(CursorAgentPermissionMode.init(rawValue:)) ?? .force
    }

    static func claudePermissionMode(for target: AgentExecutionTarget) -> ClaudeAgentPermissionMode {
        permissionModes(for: target)[AgentCLIKind.claude.rawValue]
            .flatMap(ClaudeAgentPermissionMode.init(rawValue:)) ?? .bypass
    }

    static func codexPermissionMode(for target: AgentExecutionTarget) -> CodexAgentPermissionMode {
        permissionModes(for: target)[AgentCLIKind.codex.rawValue]
            .flatMap(CodexAgentPermissionMode.init(rawValue:)) ?? .workspaceWrite
    }

    /// Favorites for the Agent settings editing target.
    static var agentFavorites: [AgentFavorite] {
        get { agentFavorites(for: agentSettingsTarget) }
        set {
            updateSettingsBucket(for: agentSettingsTarget) { $0.favorites = newValue }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func agentFavorites(for target: AgentExecutionTarget) -> [AgentFavorite] {
        settingsBucket(for: target).favorites ?? []
    }

    private static func currentFavoriteIDs(for target: AgentExecutionTarget) -> [String: String] {
        settingsBucket(for: target).currentFavoriteIDs ?? [:]
    }

    static func currentAgentFavoriteID(for kind: AgentCLIKind, target: AgentExecutionTarget? = nil) -> UUID? {
        let t = target ?? agentSettingsTarget
        guard let raw = currentFavoriteIDs(for: t)[kind.rawValue] else { return nil }
        return UUID(uuidString: raw)
    }

    static func setCurrentAgentFavoriteID(_ id: UUID, for kind: AgentCLIKind, target: AgentExecutionTarget? = nil) {
        let t = target ?? agentSettingsTarget
        updateSettingsBucket(for: t) { bucket in
            var map = bucket.currentFavoriteIDs ?? [:]
            map[kind.rawValue] = id.uuidString
            bucket.currentFavoriteIDs = map
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static var currentAgentFavorite: AgentFavorite {
        let target = agentSettingsTarget
        ensureAgentFavorites(for: target)
        let kind = agentCLI(for: target)
        if let id = currentAgentFavoriteID(for: kind, target: target),
           let fav = agentFavorites(for: target).first(where: { $0.id == id && $0.cliKind == kind }) {
            return fav
        }
        return favorites(for: kind, target: target).first { $0.isBuiltIn }
            ?? AgentFavorite.builtInDefault(for: kind)
    }

    static func favorites(for kind: AgentCLIKind, target: AgentExecutionTarget? = nil) -> [AgentFavorite] {
        let t = target ?? agentSettingsTarget
        ensureAgentFavorites(for: t)
        return agentFavorites(for: t).filter { $0.cliKind == kind }
    }

    static func ensureAgentFavorites(for target: AgentExecutionTarget? = nil) {
        let t = target ?? agentSettingsTarget
        var list = agentFavorites(for: t)
        var mutated = false
        for kind in AgentCLIKind.allCases {
            let builtin = AgentFavorite.builtInDefault(for: kind)
            if let idx = list.firstIndex(where: { $0.cliKind == kind && ($0.isBuiltIn || $0.id == builtin.id) }) {
                var fav = list[idx]
                var fix = false
                if fav.id != builtin.id { fav.id = builtin.id; fix = true }
                if !fav.isBuiltIn { fav.isBuiltIn = true; fix = true }
                if !fav.modelId.isEmpty { fav.modelId = ""; fix = true }
                if fav.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fav.title = "Default"; fix = true
                }
                if fav.modelTitle.isEmpty { fav.modelTitle = kind.defaultModelTitle; fix = true }
                if fix {
                    list[idx] = fav
                    mutated = true
                }
            } else {
                list.insert(builtin, at: 0)
                mutated = true
            }
        }
        var map = currentFavoriteIDs(for: t)
        for kind in AgentCLIKind.allCases {
            let forCLI = list.filter { $0.cliKind == kind }
            let raw = map[kind.rawValue]
            let ok = raw.flatMap(UUID.init(uuidString:)).map { id in forCLI.contains(where: { $0.id == id }) } ?? false
            if !ok {
                let fallback = forCLI.first(where: { $0.isBuiltIn })?.id ?? kind.defaultFavoriteID
                map[kind.rawValue] = fallback.uuidString
                mutated = true
            }
        }
        if mutated {
            updateSettingsBucket(for: t) { bucket in
                bucket.favorites = list
                bucket.currentFavoriteIDs = map
            }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func addAgentFavorite(_ favorite: AgentFavorite) {
        let t = agentSettingsTarget
        ensureAgentFavorites(for: t)
        var list = agentFavorites(for: t)
        list.append(favorite)
        updateSettingsBucket(for: t) { $0.favorites = list }
        setCurrentAgentFavoriteID(favorite.id, for: favorite.cliKind, target: t)
    }

    @discardableResult
    static func removeAgentFavorite(_ id: UUID) -> Bool {
        let t = agentSettingsTarget
        ensureAgentFavorites(for: t)
        var list = agentFavorites(for: t)
        guard let fav = list.first(where: { $0.id == id }) else { return false }
        let others = list.filter { $0.cliKind == fav.cliKind && $0.id != id }
        if others.isEmpty { return false }
        if fav.isBuiltIn { return false }
        list.removeAll { $0.id == id }
        updateSettingsBucket(for: t) { $0.favorites = list }
        if currentAgentFavoriteID(for: fav.cliKind, target: t) == id {
            let fallback = others.first(where: { $0.isBuiltIn })?.id ?? others[0].id
            setCurrentAgentFavoriteID(fallback, for: fav.cliKind, target: t)
        } else {
            NotificationCenter.default.post(name: changed, object: nil)
        }
        return true
    }

    static func selectAgentFavorite(_ id: UUID) {
        let t = agentSettingsTarget
        ensureAgentFavorites(for: t)
        guard let fav = agentFavorites(for: t).first(where: { $0.id == id }),
              fav.cliKind == agentCLI(for: t) else { return }
        setCurrentAgentFavoriteID(id, for: fav.cliKind, target: t)
    }

    static func favoriteForNewSession(cli: AgentCLIKind, lastSession: AgentSession?, target: AgentExecutionTarget? = nil) -> AgentFavorite {
        let t = target ?? runtimeAgentTarget
        ensureAgentFavorites(for: t)
        let available = favorites(for: cli, target: t)

        if let last = lastSession, last.cliKind == cli {
            if let id = last.favoriteId,
               let match = available.first(where: { $0.id == id }) {
                setCurrentAgentFavoriteID(match.id, for: cli, target: t)
                return match
            }
            let lastModel = last.modelId ?? ""
            let lastEffort = last.effort
            if let match = available.first(where: {
                $0.modelId == lastModel && ($0.effort ?? nil) == lastEffort
            }) {
                setCurrentAgentFavoriteID(match.id, for: cli, target: t)
                return match
            }
        }

        let currentID = currentAgentFavoriteID(for: cli, target: t)
        let current = available.first(where: { $0.id == currentID })
            ?? available.first(where: { $0.isBuiltIn })
            ?? AgentFavorite.builtInDefault(for: cli)
        setCurrentAgentFavoriteID(current.id, for: cli, target: t)
        return current
    }

    static func updateAgentFavoriteTitle(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let t = agentSettingsTarget
        var list = agentFavorites(for: t)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].title = trimmed
        updateSettingsBucket(for: t) { $0.favorites = list }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    // MARK: - Workspaces (local + SSH)

    static var agentWorkspaceRefs: [AgentWorkspaceRef] {
        get {
            migrateLegacyWorkspacesIfNeeded()
            guard let data = defaults.data(forKey: "agentWorkspaceRefs") else { return [] }
            return (try? JSONDecoder().decode([AgentWorkspaceRef].self, from: data)) ?? []
        }
        set {
            writeWorkspaceRefs(newValue)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private static var didMigrateWorkspaces = false

    private static func migrateLegacyWorkspacesIfNeeded() {
        guard !didMigrateWorkspaces else { return }
        didMigrateWorkspaces = true
        if defaults.data(forKey: "agentWorkspaceRefs") != nil { return }
        let legacyPaths: [String]
        if let stored = defaults.stringArray(forKey: "agentWorkspaces") {
            var seen = Set<String>()
            legacyPaths = stored
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        } else {
            let legacy = (defaults.string(forKey: "agentWorkspace") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            legacyPaths = legacy.isEmpty ? [] : [legacy]
        }
        let refs = legacyPaths.map { AgentWorkspaceRef.local($0) }
        writeWorkspaceRefs(refs)
        if let rootPath = defaults.string(forKey: "agentWorkspaceRoot"),
           let match = refs.first(where: { $0.path == rootPath }) {
            defaults.set(match.id.uuidString, forKey: "agentWorkspaceRootID")
        } else if let first = refs.first {
            defaults.set(first.id.uuidString, forKey: "agentWorkspaceRootID")
        }
        // Migrate worktree memory path→path into id→path
        if let old = defaults.dictionary(forKey: "agentWorktreeByRoot") as? [String: String] {
            var next: [String: String] = [:]
            for (path, worktree) in old {
                if let ref = refs.first(where: { $0.path == path }) {
                    next[ref.id.uuidString] = worktree
                }
            }
            defaults.set(next, forKey: "agentWorktreeByRootID")
        }
    }

    private static func writeWorkspaceRefs(_ refs: [AgentWorkspaceRef]) {
        var seen = Set<String>()
        let cleaned = refs.filter { ref in
            let key = "\(ref.connectionID?.uuidString ?? "local")|\(ref.path)"
            return !ref.path.isEmpty && seen.insert(key).inserted
        }
        defaults.set((try? JSONEncoder().encode(cleaned)) ?? Data(), forKey: "agentWorkspaceRefs")
        // Mirror path arrays for any leftover readers / reset.
        defaults.set(cleaned.map(\.path), forKey: "agentWorkspaces")
    }

    /// Path-only list (legacy). Prefer `agentWorkspaceRefs` when connection matters.
    static var agentWorkspaces: [String] {
        get { agentWorkspaceRefs.map(\.path) }
        set {
            // Only used by reset/migration paths — treat as local folders.
            let refs = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { AgentWorkspaceRef.local($0) }
            agentWorkspaceRefs = refs
        }
    }

    static var currentWorkspaceRef: AgentWorkspaceRef? {
        let refs = agentWorkspaceRefs
        if let raw = defaults.string(forKey: "agentWorkspaceRootID"),
           let id = UUID(uuidString: raw),
           let match = refs.first(where: { $0.id == id }) {
            return match
        }
        return refs.first
    }

    static var agentWorkspaceConnectionID: UUID? {
        currentWorkspaceRef?.connectionID
    }

    /// Registered folder selected in the sessions workspace picker.
    static var agentWorkspaceRoot: String {
        get { currentWorkspaceRef?.path ?? "" }
        set {
            let path = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ref = agentWorkspaceRefs.first(where: {
                $0.path == path && $0.connectionID == currentWorkspaceRef?.connectionID
            }) ?? agentWorkspaceRefs.first(where: { $0.path == path }) else { return }
            selectAgentWorkspaceRef(ref.id)
        }
    }

    /// Active working directory for new agent sessions (registered root or a git worktree under it).
    static var agentWorkspace: String {
        get {
            let active = (defaults.string(forKey: "agentWorkspace") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !active.isEmpty { return active }
            return agentWorkspaceRoot
        }
        set {
            selectWorkspace(path: newValue, connectionID: currentWorkspaceRef?.connectionID)
        }
    }

    /// Switch active folder (and machine) — used by notifications / session reveal.
    /// Never invents a local ref for an SSH path.
    static func selectWorkspace(path: String, connectionID: UUID?) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        if let ref = agentWorkspaceRefs.first(where: {
            $0.connectionID == connectionID && ($0.path == path || path.hasPrefix($0.path + "/"))
        }) {
            // Set root + connection first so worktree memory keys the right machine.
            defaults.set(ref.id.uuidString, forKey: "agentWorkspaceRootID")
            defaults.set(ref.path, forKey: "agentWorkspaceRoot")
            if path == ref.path {
                let active = rememberedWorktree(forRootID: ref.id) ?? ref.path
                defaults.set(active, forKey: "agentWorkspace")
            } else {
                rememberWorktree(path, forRootID: ref.id)
                defaults.set(path, forKey: "agentWorkspace")
            }
            NotificationCenter.default.post(name: changed, object: nil)
            return
        }
        if let ref = agentWorkspaceRefs.first(where: { $0.path == path }) {
            selectAgentWorkspaceRef(ref.id)
            return
        }
        // Unknown path: auto-register only for local machines.
        if connectionID == nil {
            addAgentWorkspaceRef(.local(path))
            return
        }
        defaults.set(path, forKey: "agentWorkspace")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func addAgentWorkspace(_ path: String) {
        addAgentWorkspaceRef(.local(path))
    }

    static func addAgentWorkspaceRef(_ ref: AgentWorkspaceRef) {
        let trimmed = ref.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var refs = agentWorkspaceRefs
        if let existing = refs.first(where: { $0.connectionID == ref.connectionID && $0.path == trimmed }) {
            selectAgentWorkspaceRef(existing.id)
            return
        }
        var next = ref
        next.path = trimmed
        refs.append(next)
        writeWorkspaceRefs(refs)
        selectAgentWorkspaceRef(next.id)
    }

    static func removeAgentWorkspace(_ path: String) {
        if let ref = agentWorkspaceRefs.first(where: { $0.path == path && $0.connectionID == nil })
            ?? agentWorkspaceRefs.first(where: { $0.path == path }) {
            removeAgentWorkspaceRef(ref.id)
        }
    }

    static func removeAgentWorkspaceRef(_ id: UUID) {
        clearRememberedWorktree(forRootID: id)
        let refs = agentWorkspaceRefs.filter { $0.id != id }
        writeWorkspaceRefs(refs)
        if currentWorkspaceRef?.id == id || defaults.string(forKey: "agentWorkspaceRootID") == id.uuidString {
            if let first = refs.first {
                selectAgentWorkspaceRef(first.id)
            } else {
                defaults.removeObject(forKey: "agentWorkspaceRootID")
                defaults.removeObject(forKey: "agentWorkspace")
                defaults.removeObject(forKey: "agentWorkspaceRoot")
                NotificationCenter.default.post(name: changed, object: nil)
            }
        } else {
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func selectAgentWorkspace(_ path: String) {
        if let ref = agentWorkspaceRefs.first(where: { $0.path == path }) {
            selectAgentWorkspaceRef(ref.id)
        }
    }

    static func selectAgentWorkspaceRef(_ id: UUID) {
        guard let ref = agentWorkspaceRefs.first(where: { $0.id == id }) else { return }
        defaults.set(ref.id.uuidString, forKey: "agentWorkspaceRootID")
        defaults.set(ref.path, forKey: "agentWorkspaceRoot")
        let active = rememberedWorktree(forRootID: ref.id) ?? ref.path
        defaults.set(active, forKey: "agentWorkspace")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func selectAgentWorktree(_ path: String, root: String) {
        let worktree = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootPath = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !worktree.isEmpty, !rootPath.isEmpty else { return }
        let rootRef = agentWorkspaceRefs.first(where: {
            $0.path == rootPath && $0.connectionID == currentWorkspaceRef?.connectionID
        }) ?? agentWorkspaceRefs.first(where: { $0.path == rootPath })
        guard let rootRef else { return }
        rememberWorktree(worktree, forRootID: rootRef.id)
        defaults.set(rootRef.id.uuidString, forKey: "agentWorkspaceRootID")
        defaults.set(rootRef.path, forKey: "agentWorkspaceRoot")
        defaults.set(worktree, forKey: "agentWorkspace")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Branch name for the active working directory (empty when not a git repo).
    /// Local only — never blocks the main thread on SSH (SessionStore probes remotes async).
    static var agentGitBranch: String {
        if agentWorkspaceConnectionID != nil { return "" }
        return GitWorkspace.currentBranch(in: agentWorkspace, connection: nil) ?? ""
    }

    private static func rememberedWorktree(forRootID id: UUID) -> String? {
        let map = defaults.dictionary(forKey: "agentWorktreeByRootID") as? [String: String] ?? [:]
        let value = map[id.uuidString]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func rememberWorktree(_ path: String, forRootID id: UUID) {
        var map = defaults.dictionary(forKey: "agentWorktreeByRootID") as? [String: String] ?? [:]
        map[id.uuidString] = path
        defaults.set(map, forKey: "agentWorktreeByRootID")
    }

    private static func clearRememberedWorktree(forRootID id: UUID) {
        var map = defaults.dictionary(forKey: "agentWorktreeByRootID") as? [String: String] ?? [:]
        map.removeValue(forKey: id.uuidString)
        defaults.set(map, forKey: "agentWorktreeByRootID")
    }

    static var screenshotsFolder: String {
        get {
            if let stored = defaults.string(forKey: "screenshotsFolder"), !stored.isEmpty {
                return stored
            }
            return defaultScreenshotsFolder
        }
        set { set(newValue, "screenshotsFolder") }
    }

    static var defaultScreenshotsFolder: String {
        NSString(string: "~/Documents/AiHand").expandingTildeInPath
    }

    /// Preferred size when a chat is open (total panel width + height). List-only mode is fixed.
    static let sessionsPanelDefaultWidth: CGFloat = 900
    static let sessionsPanelDefaultHeight: CGFloat = 400

    /// Persisted expanded (chat open) panel width. Caps applied at layout time.
    static var sessionsPanelWidth: CGFloat {
        get {
            (defaults.object(forKey: "sessionsPanelWidth") as? Double)
                .map { CGFloat($0) } ?? sessionsPanelDefaultWidth
        }
        set { defaults.set(Double(newValue), forKey: "sessionsPanelWidth") }
    }

    /// Persisted expanded (chat open) panel height. Caps applied at layout time.
    static var sessionsPanelHeight: CGFloat {
        get {
            (defaults.object(forKey: "sessionsPanelHeight") as? Double)
                .map { CGFloat($0) } ?? sessionsPanelDefaultHeight
        }
        set { defaults.set(Double(newValue), forKey: "sessionsPanelHeight") }
    }

    /// Origin of the sessions *list* with chat closed (AppKit coords).
    /// Expanded chat frames keep this origin and grow to the right.
    /// `nil` = default trailing dock.
    static var sessionsPanelOrigin: CGPoint? {
        get {
            guard let x = defaults.object(forKey: "sessionsPanelOriginX") as? Double,
                  let y = defaults.object(forKey: "sessionsPanelOriginY") as? Double else {
                return nil
            }
            return CGPoint(x: x, y: y)
        }
        set {
            if let newValue {
                defaults.set(Double(newValue.x), forKey: "sessionsPanelOriginX")
                defaults.set(Double(newValue.y), forKey: "sessionsPanelOriginY")
            } else {
                defaults.removeObject(forKey: "sessionsPanelOriginX")
                defaults.removeObject(forKey: "sessionsPanelOriginY")
            }
        }
    }

    /// Origin of the expanded list+chat panel (AppKit coords). Used when reopening
    /// after drawing mode hides the panel so chat doesn’t jump to a clamped corner.
    static var sessionsPanelExpandedOrigin: CGPoint? {
        get {
            guard let x = defaults.object(forKey: "sessionsPanelExpandedOriginX") as? Double,
                  let y = defaults.object(forKey: "sessionsPanelExpandedOriginY") as? Double else {
                return nil
            }
            return CGPoint(x: x, y: y)
        }
        set {
            if let newValue {
                defaults.set(Double(newValue.x), forKey: "sessionsPanelExpandedOriginX")
                defaults.set(Double(newValue.y), forKey: "sessionsPanelExpandedOriginY")
            } else {
                defaults.removeObject(forKey: "sessionsPanelExpandedOriginX")
                defaults.removeObject(forKey: "sessionsPanelExpandedOriginY")
            }
        }
    }

    @discardableResult
    static func ensureScreenshotsFolder() -> String {
        let path = screenshotsFolder
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        return path
    }

    static let maxPinned = 8

    static var pinnedStyles: [PointerStyle] {
        get {
            guard let raw = defaults.stringArray(forKey: "pinnedStyles") else {
                return PointerStyle.defaultPinned
            }
            var seen = Set<PointerStyle>()
            let pinned = raw.compactMap(PointerStyle.init(rawValue:)).filter { seen.insert($0).inserted }
            return pinned.isEmpty ? PointerStyle.defaultPinned : pinned
        }
        set { set(newValue.map(\.rawValue), "pinnedStyles") }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.write("launch at login change failed: \(error.localizedDescription)")
            }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func resetAll() {
        for key in ["shortcut.toggle", "shortcut.clear", "shortcut.sessions", "pointerSize", "showShadow", "theme", "fadeSeconds",
                    "sound.hands", "sound.laser", "interactKey", "interactKeepsHand", "pinnedStyles", "pointerStyle",
                    "inkChoice", "showInkButton", "drawTool", "strokeThickness", "captureScope", "tapSound", "agentCLI",
                    "agentPermissionModes", "agentSettingsByTarget", "agentSettingsTarget",
                    "sshConnections",
                    "agentWorkspace", "agentWorkspaceRoot", "agentWorkspaces", "agentWorktreeByRoot",
                    "agentWorkspaceRefs", "agentWorkspaceRootID", "agentWorktreeByRootID",
                    "agentFavorites", "currentAgentFavoriteID", "currentAgentFavoriteIDs", "screenshotsFolder",
                    "sessionsPanelWidth", "sessionsPanelHeight", "sessionsPanelOriginX", "sessionsPanelOriginY",
                    "sessionsPanelExpandedOriginX", "sessionsPanelExpandedOriginY"] {
            defaults.removeObject(forKey: key)
        }
        didMigrateAgentSettings = false
        didMigrateWorkspaces = false
        SSHClient.closeAllMasters()
        applyTheme()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func loadShortcut(_ key: String) -> Shortcut? {
        guard let d = defaults.dictionary(forKey: key),
              let code = d["keyCode"] as? Int, let mods = d["modifiers"] as? Int, let label = d["display"] as? String else {
            return nil
        }
        return Shortcut(keyCode: UInt32(code), modifiers: UInt32(mods), display: label)
    }

    private static func saveShortcut(_ s: Shortcut, _ key: String) {
        set(["keyCode": Int(s.keyCode), "modifiers": Int(s.modifiers), "display": s.display], key)
    }
}
