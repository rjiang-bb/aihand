import XCTest
@testable import AiHand

final class VideoDestinationTests: XCTestCase {
    func testDestinationsCoverSaveCommentSendAndDiscard() {
        let all = VideoDestination.allCases
        XCTAssertEqual(all, [.comment, .save, .send, .discard])
        XCTAssertEqual(VideoDestination.comment.title, "Save + comment")
        XCTAssertEqual(VideoDestination.save.title, "Save video")
        XCTAssertEqual(VideoDestination.send.title, "Send to agent")
        XCTAssertEqual(VideoDestination.discard.title, "Discard")
        XCTAssertTrue(VideoDestination.discard.isDestructive)
        XCTAssertFalse(VideoDestination.send.isDestructive)
    }

    func testStoppedChromeCopy() {
        XCTAssertEqual(VideoToolbarChrome.stoppedTitle, "Stopped")
        XCTAssertNotEqual(VideoToolbarChrome.stoppedTitle, "Ready")
    }
}
