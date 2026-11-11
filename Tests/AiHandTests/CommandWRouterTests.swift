import XCTest
@testable import AiHand

final class CommandWRouterTests: XCTestCase {
    func testPreviewBeatsSettingsAndSessions() {
        XCTAssertEqual(
            CommandWRouter.action(previewIsKey: true, settingsIsKey: true, sessionsIsKey: true),
            .closePreview
        )
    }

    func testSettingsBeatsSessions() {
        XCTAssertEqual(
            CommandWRouter.action(previewIsKey: false, settingsIsKey: true, sessionsIsKey: true),
            .closeSettings
        )
    }

    func testSessionsArchivesWhenKey() {
        XCTAssertEqual(
            CommandWRouter.action(previewIsKey: false, settingsIsKey: false, sessionsIsKey: true),
            .archiveSession
        )
    }

    func testFallbackClosesKeyWindow() {
        XCTAssertEqual(
            CommandWRouter.action(previewIsKey: false, settingsIsKey: false, sessionsIsKey: false),
            .closeKeyWindow
        )
    }
}
