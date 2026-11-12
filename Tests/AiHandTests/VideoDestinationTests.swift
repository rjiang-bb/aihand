import XCTest
@testable import AiHand

final class VideoDestinationTests: XCTestCase {
    func testDestinationsCoverSaveCommentSendAndDiscard() {
        let all = VideoDestination.allCases
        XCTAssertEqual(all, [.comment, .save, .send, .discard])
        XCTAssertEqual(VideoDestination.comment.title, "Save + comment")
        XCTAssertEqual(VideoDestination.save.title, "Save video")
        XCTAssertEqual(VideoDestination.send.title, "Attach to chat")
        XCTAssertEqual(VideoDestination.discard.title, "Discard")
        XCTAssertTrue(VideoDestination.discard.isDestructive)
        XCTAssertFalse(VideoDestination.send.isDestructive)
    }

    func testStoppedChromeCopy() {
        XCTAssertEqual(VideoToolbarChrome.stoppedTitle, "Stopped")
        XCTAssertNotEqual(VideoToolbarChrome.stoppedTitle, "Ready")
    }

    func testShortcutsAreDistinctAndRightAlignedCopy() {
        let shortcuts = VideoDestination.allCases.map(\.shortcut)
        XCTAssertEqual(Set(shortcuts).count, shortcuts.count)
        XCTAssertEqual(VideoDestination.comment.shortcut, "⌘S")
        XCTAssertEqual(VideoDestination.save.shortcut, "⌘⇧S")
        XCTAssertEqual(VideoDestination.send.shortcut, "⌘↩")
        XCTAssertEqual(VideoDestination.discard.shortcut, "Esc")
    }

    func testHoverBorderMatchesSessionSoftChrome() {
        let dark = SoftChrome.hoverInnerBorderNSColor(dark: true)
        let light = SoftChrome.hoverInnerBorderNSColor(dark: false)
        XCTAssertEqual(dark.alphaComponent, 0.92, accuracy: 0.001)
        XCTAssertEqual(dark.whiteComponent, 1, accuracy: 0.001)
        XCTAssertEqual(light.alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(light.whiteComponent, 0.28, accuracy: 0.001)
    }
}
