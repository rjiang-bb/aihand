import Foundation

/// ⌘W always targets the focused window — preview / Settings close first; archive only when the sessions panel is key.
enum CommandWRouter {
    enum Action: Equatable {
        case closePreview
        case closeSettings
        case archiveSession
        case closeKeyWindow
    }

    static func action(
        previewIsKey: Bool,
        settingsIsKey: Bool,
        sessionsIsKey: Bool
    ) -> Action {
        if previewIsKey { return .closePreview }
        if settingsIsKey { return .closeSettings }
        if sessionsIsKey { return .archiveSession }
        return .closeKeyWindow
    }
}
