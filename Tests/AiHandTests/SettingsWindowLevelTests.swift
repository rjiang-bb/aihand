import AppKit
import XCTest
@testable import AiHand

final class SettingsWindowLevelTests: XCTestCase {
    func testSettingsLevelIsAboveSessionsAndChatImagePreviews() {
        let sessions = NSWindow.Level.floating.rawValue + 2
        let chatImagePreview = NSWindow.Level.floating.rawValue + 3
        XCTAssertGreaterThan(
            SettingsWindow.windowLevel.rawValue,
            sessions,
            "Settings must stack above the sessions/chat panel"
        )
        XCTAssertGreaterThan(
            SettingsWindow.windowLevel.rawValue,
            chatImagePreview,
            "Settings must stack above chat attachment previews"
        )
    }
}
