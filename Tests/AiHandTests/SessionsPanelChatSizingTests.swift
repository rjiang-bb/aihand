import XCTest
@testable import AiHand

final class SessionsPanelChatSizingTests: SandboxedTestCase {
    func testPreferredHeightIgnoresListLength() {
        let saved: CGFloat = Preferences.sessionsPanelDefaultHeight
        let maxH: CGFloat = 2000
        let shortList = SessionsPanelChatSizing.preferredSize(
            savedWidth: 900, savedHeight: saved, maxWidth: 1200, maxHeight: maxH
        )
        let tallListFloor = SessionsListMetrics.panelHeight(sessionCount: 9)
        XCTAssertGreaterThan(tallListFloor, saved, "precondition: full list taller than default chat")

        let afterManySessions = SessionsPanelChatSizing.preferredSize(
            savedWidth: 900, savedHeight: saved, maxWidth: 1200, maxHeight: maxH
        )
        XCTAssertEqual(shortList.height, saved)
        XCTAssertEqual(afterManySessions.height, saved)
        XCTAssertLessThan(afterManySessions.height, tallListFloor)
    }

    func testPreferredHeightHonorsSavedDragSize() {
        let dragged: CGFloat = 720
        let size = SessionsPanelChatSizing.preferredSize(
            savedWidth: 1000, savedHeight: dragged, maxWidth: 1400, maxHeight: 2000
        )
        XCTAssertEqual(size.height, dragged)
        XCTAssertEqual(size.width, 1000)
    }

    func testPreferredHeightFloorsAtDefault() {
        let size = SessionsPanelChatSizing.preferredSize(
            savedWidth: 100, savedHeight: 50, maxWidth: 1400, maxHeight: 2000
        )
        XCTAssertEqual(size.height, Preferences.sessionsPanelDefaultHeight)
        XCTAssertEqual(size.width, Preferences.sessionsPanelDefaultWidth)
    }

    func testPreferredHeightClampsToScreen() {
        let size = SessionsPanelChatSizing.preferredSize(
            savedWidth: 2000, savedHeight: 1800, maxWidth: 800, maxHeight: 600
        )
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }
}
