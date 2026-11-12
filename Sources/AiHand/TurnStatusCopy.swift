import Foundation

/// Cursor-style turn status chip copy (Worked / Thought / Exploring / Planning).
enum TurnStatusCopy {
    static let planning = "Planning next moves"
    static let thinkingLive = "Thinking…"

    static func worked(seconds: TimeInterval) -> String {
        "Worked for \(formatSeconds(seconds))"
    }

    static func thought(seconds: TimeInterval) -> String {
        "Thought \(formatSeconds(seconds))"
    }

    /// Transcript nests Thought chips + tool rows under a Worked disclosure.
    static func isWorkedChip(_ text: String) -> Bool {
        text.hasPrefix("Worked for ")
    }

    static func isThoughtChip(_ text: String) -> Bool {
        text.hasPrefix("Thought ")
    }

    /// Aggregate tool activity for the live footer / collapsed group label.
    /// Returns nil when there are no categorized tools.
    static func exploring(toolTexts: [String]) -> String? {
        var files = 0
        var searches = 0
        var commands = 0
        for text in toolTexts {
            switch category(for: text) {
            case .file: files += 1
            case .search: searches += 1
            case .command: commands += 1
            case .other: break
            }
        }
        var parts: [String] = []
        if files > 0 {
            parts.append(files == 1 ? "1 file" : "\(files) files")
        }
        if searches > 0 {
            parts.append(searches == 1 ? "1 search" : "\(searches) searches")
        }
        if commands > 0 {
            parts.append(commands == 1 ? "1 command" : "\(commands) commands")
        }
        guard !parts.isEmpty else { return nil }
        return "Exploring " + parts.joined(separator: ", ")
    }

    enum ToolCategory: Equatable {
        case file
        case search
        case command
        case other
    }

    static func category(for toolText: String) -> ToolCategory {
        let t = toolText.lowercased()
        if t.hasPrefix("reading") || t.hasPrefix("read ")
            || t.hasPrefix("editing") || t.hasPrefix("writing") || t.hasPrefix("wrote")
            || t.hasPrefix("deleting") || t.hasPrefix("listed") {
            return .file
        }
        if t.hasPrefix("search") || t.hasPrefix("grep") || t.hasPrefix("glob") || t.hasPrefix("fetch") {
            return .search
        }
        if t.hasPrefix("ran") || t.hasPrefix("running") || t.hasPrefix("shell") || t.hasPrefix("command") {
            return .command
        }
        return .other
    }

    static func formatSeconds(_ seconds: TimeInterval) -> String {
        let n = max(0, Int(seconds.rounded()))
        if n < 60 { return "\(n)s" }
        let m = n / 60
        let s = n % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }
}
