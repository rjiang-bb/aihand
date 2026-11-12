import XCTest
@testable import AiHand

final class OverlayCursorTests: XCTestCase {
    func testAnnotateCommentForcesSystemCursor() {
        XCTAssertTrue(
            OverlayController.wantsSystemCursor(
                ownMenuOpen: true,
                drawing: false,
                interactKeepsHand: true,
                interacting: false,
                overMenu: false
            ),
            "comment box must show the system cursor even when interact keeps the hand"
        )
        XCTAssertTrue(
            OverlayController.wantsSystemCursor(
                ownMenuOpen: true,
                drawing: true,
                interactKeepsHand: false,
                interacting: false,
                overMenu: false
            ),
            "comment box wins over an in-progress stroke flag"
        )
    }

    func testDrawingKeepsHiddenCursorWithoutComment() {
        XCTAssertFalse(
            OverlayController.wantsSystemCursor(
                ownMenuOpen: false,
                drawing: true,
                interactKeepsHand: false,
                interacting: false,
                overMenu: false
            )
        )
        XCTAssertFalse(
            OverlayController.wantsSystemCursor(
                ownMenuOpen: false,
                drawing: false,
                interactKeepsHand: true,
                interacting: true,
                overMenu: false
            )
        )
        XCTAssertTrue(
            OverlayController.wantsSystemCursor(
                ownMenuOpen: false,
                drawing: false,
                interactKeepsHand: false,
                interacting: true,
                overMenu: false
            )
        )
    }
}
