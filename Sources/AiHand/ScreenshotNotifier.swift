import AppKit
import UserNotifications

/// Banner when a drawing-mode screenshot is saved to disk.
enum ScreenshotNotifier {
    static let categoryID = "screenshot.saved"
    static let pathKey = "screenshotPath"

    static func notifySaved(path: String) {
        let content = UNMutableNotificationContent()
        content.title = "Screenshot saved"
        content.body = path
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = [pathKey: path]

        if let attachment = makeAttachment(from: path) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: "screenshot-saved-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.write("screenshot notification failed: \(error.localizedDescription)")
            }
        }
    }

    static func path(from response: UNNotificationResponse) -> String? {
        response.notification.request.content.userInfo[pathKey] as? String
    }

    private static func makeAttachment(from path: String) -> UNNotificationAttachment? {
        let source = URL(fileURLWithPath: path)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aihand-shot-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: source, to: temp)
            return try UNNotificationAttachment(
                identifier: "preview",
                url: temp,
                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]
            )
        } catch {
            Log.write("screenshot notification attachment failed: \(error.localizedDescription)")
            return nil
        }
    }
}
