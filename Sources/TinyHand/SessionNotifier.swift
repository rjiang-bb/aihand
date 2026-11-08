import AppKit
import UserNotifications

/// Desktop alerts when an agent session finishes a turn.
enum SessionNotifier {
    static let categoryID = "session.completed"
    static let sessionIDKey = "sessionID"

    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: categoryID, actions: [], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.write("notifications auth error: \(error.localizedDescription)")
            } else {
                Log.write("notifications auth granted=\(granted)")
            }
        }
    }

    static func notifyCompleted(session: AgentSession) {
        let excerpt = lastAssistantExcerpt(from: session)
        let content = UNMutableNotificationContent()
        content.title = "Finished"
        content.subtitle = session.title
        content.body = excerpt.isEmpty ? "Session completed." : excerpt
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = [sessionIDKey: session.id.uuidString]

        let request = UNNotificationRequest(
            identifier: "session-finished-\(session.id.uuidString)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.write("notification failed: \(error.localizedDescription)")
            }
        }
    }

    static func sessionID(from response: UNNotificationResponse) -> UUID? {
        let info = response.notification.request.content.userInfo
        guard let raw = info[sessionIDKey] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    private static func lastAssistantExcerpt(from session: AgentSession) -> String {
        let text = session.messages.last(where: { $0.kind == .assistant })?.text
            ?? session.preview
        return collapseWhitespace(text, limit: 180)
    }

    private static func collapseWhitespace(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
