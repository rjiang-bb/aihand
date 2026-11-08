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
    private static let defaults = UserDefaults.standard

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

    static var agentCLI: AgentCLIKind {
        get { defaults.string(forKey: "agentCLI").flatMap(AgentCLIKind.init(rawValue:)) ?? .cursor }
        set {
            defaults.set(newValue.rawValue, forKey: "agentCLI")
            ensureAgentFavorites()
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Named model (+ effort) presets, each tagged with a `cliKind`. UI shows only the active CLI’s set.
    static var agentFavorites: [AgentFavorite] {
        get {
            guard let data = defaults.data(forKey: "agentFavorites") else { return [] }
            return (try? JSONDecoder().decode([AgentFavorite].self, from: data)) ?? []
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            set(data, "agentFavorites")
        }
    }

    /// Per-CLI current favorite ids (`cliKind.rawValue` → uuid string).
    private static var currentFavoriteIDsByCLI: [String: String] {
        get { defaults.dictionary(forKey: "currentAgentFavoriteIDs") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "currentAgentFavoriteIDs") }
    }

    static func currentAgentFavoriteID(for kind: AgentCLIKind) -> UUID? {
        // Migrate legacy single-id key once.
        if let legacy = defaults.string(forKey: "currentAgentFavoriteID"),
           let uuid = UUID(uuidString: legacy) {
            var map = currentFavoriteIDsByCLI
            if map[kind.rawValue] == nil {
                map[kind.rawValue] = uuid.uuidString
                currentFavoriteIDsByCLI = map
            }
            defaults.removeObject(forKey: "currentAgentFavoriteID")
        }
        guard let raw = currentFavoriteIDsByCLI[kind.rawValue] else { return nil }
        return UUID(uuidString: raw)
    }

    static func setCurrentAgentFavoriteID(_ id: UUID, for kind: AgentCLIKind) {
        var map = currentFavoriteIDsByCLI
        map[kind.rawValue] = id.uuidString
        currentFavoriteIDsByCLI = map
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Favorite used for new sessions on the current CLI (always non-nil after ensure).
    static var currentAgentFavorite: AgentFavorite {
        ensureAgentFavorites()
        let kind = agentCLI
        if let id = currentAgentFavoriteID(for: kind),
           let fav = agentFavorites.first(where: { $0.id == id && $0.cliKind == kind }) {
            return fav
        }
        return favorites(for: kind).first { $0.isBuiltIn }
            ?? AgentFavorite.builtInDefault(for: kind)
    }

    static func favorites(for kind: AgentCLIKind) -> [AgentFavorite] {
        ensureAgentFavorites()
        return agentFavorites.filter { $0.cliKind == kind }
    }

    /// Guarantee each CLI has a Default favorite and each CLI’s current selection is valid.
    static func ensureAgentFavorites() {
        var list = agentFavorites
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
        if mutated {
            defaults.set((try? JSONEncoder().encode(list)) ?? Data(), forKey: "agentFavorites")
        }

        var map = currentFavoriteIDsByCLI
        // One-time migrate legacy global current id onto the active CLI.
        if let legacy = defaults.string(forKey: "currentAgentFavoriteID") {
            if map[agentCLI.rawValue] == nil {
                map[agentCLI.rawValue] = legacy
            }
            defaults.removeObject(forKey: "currentAgentFavoriteID")
            mutated = true
        }
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
        if map != currentFavoriteIDsByCLI {
            currentFavoriteIDsByCLI = map
            mutated = true
        }
        if mutated {
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func addAgentFavorite(_ favorite: AgentFavorite) {
        ensureAgentFavorites()
        var list = agentFavorites
        list.append(favorite)
        agentFavorites = list
        setCurrentAgentFavoriteID(favorite.id, for: favorite.cliKind)
    }

    @discardableResult
    static func removeAgentFavorite(_ id: UUID) -> Bool {
        ensureAgentFavorites()
        var list = agentFavorites
        guard let fav = list.first(where: { $0.id == id }) else { return false }
        let others = list.filter { $0.cliKind == fav.cliKind && $0.id != id }
        // Always keep at least one favorite for the CLI (the built-in Default).
        if others.isEmpty { return false }
        if fav.isBuiltIn { return false }
        list.removeAll { $0.id == id }
        defaults.set((try? JSONEncoder().encode(list)) ?? Data(), forKey: "agentFavorites")
        if currentAgentFavoriteID(for: fav.cliKind) == id {
            let fallback = others.first(where: { $0.isBuiltIn })?.id ?? others[0].id
            setCurrentAgentFavoriteID(fallback, for: fav.cliKind)
        } else {
            NotificationCenter.default.post(name: changed, object: nil)
        }
        return true
    }

    static func selectAgentFavorite(_ id: UUID) {
        ensureAgentFavorites()
        guard let fav = agentFavorites.first(where: { $0.id == id }),
              fav.cliKind == agentCLI else { return }
        setCurrentAgentFavoriteID(id, for: fav.cliKind)
    }

    /// Pick the favorite a new session should use — prefer the last session’s when still available.
    static func favoriteForNewSession(cli: AgentCLIKind, lastSession: AgentSession?) -> AgentFavorite {
        ensureAgentFavorites()
        let available = favorites(for: cli)

        if let last = lastSession, last.cliKind == cli {
            if let id = last.favoriteId,
               let match = available.first(where: { $0.id == id }) {
                setCurrentAgentFavoriteID(match.id, for: cli)
                return match
            }
            let lastModel = last.modelId ?? ""
            let lastEffort = last.effort
            if let match = available.first(where: {
                $0.modelId == lastModel && ($0.effort ?? nil) == lastEffort
            }) {
                setCurrentAgentFavoriteID(match.id, for: cli)
                return match
            }
        }

        let currentID = currentAgentFavoriteID(for: cli)
        let current = available.first(where: { $0.id == currentID })
            ?? available.first(where: { $0.isBuiltIn })
            ?? AgentFavorite.builtInDefault(for: cli)
        setCurrentAgentFavoriteID(current.id, for: cli)
        return current
    }

    static func updateAgentFavoriteTitle(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = agentFavorites
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].title = trimmed
        agentFavorites = list
    }

    /// Folders available for agent sessions. One of them is the current working folder (`agentWorkspace`).
    static var agentWorkspaces: [String] {
        get {
            if let stored = defaults.stringArray(forKey: "agentWorkspaces") {
                var seen = Set<String>()
                let cleaned = stored
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
                if !cleaned.isEmpty { return cleaned }
            }
            let legacy = (defaults.string(forKey: "agentWorkspace") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return legacy.isEmpty ? [] : [legacy]
        }
        set {
            var seen = Set<String>()
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            defaults.set(cleaned, forKey: "agentWorkspaces")
            let current = (defaults.string(forKey: "agentWorkspace") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                defaults.removeObject(forKey: "agentWorkspace")
            } else if !cleaned.contains(current) {
                defaults.set(cleaned[0], forKey: "agentWorkspace")
            }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Current working folder for new agent sessions.
    static var agentWorkspace: String {
        get {
            let folders = agentWorkspaces
            let stored = (defaults.string(forKey: "agentWorkspace") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if folders.contains(stored) { return stored }
            return folders.first ?? ""
        }
        set {
            let path = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return }
            var folders = agentWorkspaces
            if !folders.contains(path) {
                folders.append(path)
                defaults.set(folders, forKey: "agentWorkspaces")
            }
            set(path, "agentWorkspace")
        }
    }

    static func addAgentWorkspace(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var folders = agentWorkspaces
        if !folders.contains(trimmed) {
            folders.append(trimmed)
            agentWorkspaces = folders
        }
        selectAgentWorkspace(trimmed)
    }

    static func removeAgentWorkspace(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        agentWorkspaces = agentWorkspaces.filter { $0 != trimmed }
    }

    static func selectAgentWorkspace(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard agentWorkspaces.contains(trimmed) else { return }
        set(trimmed, "agentWorkspace")
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
                    "inkChoice", "showInkButton", "drawTool", "strokeThickness", "captureScope", "tapSound", "agentCLI", "agentWorkspace", "agentWorkspaces",
                    "agentFavorites", "currentAgentFavoriteID", "currentAgentFavoriteIDs", "screenshotsFolder",
                    "sessionsPanelWidth", "sessionsPanelHeight", "sessionsPanelOriginX", "sessionsPanelOriginY",
                    "sessionsPanelExpandedOriginX", "sessionsPanelExpandedOriginY"] {
            defaults.removeObject(forKey: key)
        }
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
