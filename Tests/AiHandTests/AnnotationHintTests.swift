import XCTest
@testable import AiHand

final class AnnotationHintTests: XCTestCase {
    func testModeBadgeTitles() {
        XCTAssertEqual(ModeBadgePanel.Mode.drawing.title, "Drawing mode")
        XCTAssertEqual(ModeBadgePanel.Mode.video.title, "Video mode")
    }

    func testModeBadgeSitsAboveChrome() {
        XCTAssertEqual(AnnotationChromeLayout.modeBadgeOriginY(belowChromeMaxY: 200), 210)
    }

    func testChromeLayoutDocksBelowHandPicker() {
        let minY: CGFloat = 100
        let raised = AnnotationChromeLayout.raisedHintBottomInset
        XCTAssertEqual(raised, 14 + 56 + 12)
        XCTAssertEqual(AnnotationChromeLayout.hintOriginY(visibleMinY: minY, docked: false), minY + raised)
        XCTAssertEqual(AnnotationChromeLayout.hintOriginY(visibleMinY: minY, docked: true), minY + 14)
        XCTAssertEqual(AnnotationChromeLayout.dockedHintBottomInset, 14)

        // Destination uses docked flag + height, not the hint's current (possibly mid-slide) origin.
        let midSlideHint = CGRect(x: 0, y: minY + 80, width: 200, height: 30)
        XCTAssertEqual(
            AnnotationChromeLayout.toolsOriginY(hintFrame: midSlideHint, visibleMinY: minY, docked: true),
            minY + 14 + 30 + 10
        )
        XCTAssertEqual(
            AnnotationChromeLayout.toolsOriginY(hintFrame: midSlideHint, visibleMinY: minY, docked: false),
            minY + raised + 30 + 10
        )
        XCTAssertEqual(
            AnnotationChromeLayout.toolsOriginY(hintFrame: .zero, visibleMinY: minY, docked: true),
            minY + 14 + 50
        )
    }

    func testDrawingHintsIncludeCmdDVideoToggle() {
        let keys = AnnotationHintPanel.drawingParts.map(\.0)
        XCTAssertTrue(keys.contains("⌘D"), keys.joined(separator: ", "))
        XCTAssertTrue(keys.contains("Right-drag"), "right-drag video entry remains")
        XCTAssertEqual(
            AnnotationHintPanel.drawingParts.first { $0.0 == "Esc" }?.1,
            "clear & exit"
        )
        XCTAssertEqual(
            AnnotationHintPanel.drawingParts.first { $0.0 == "Enter" }?.1,
            "comment & send"
        )
        XCTAssertEqual(
            AnnotationHintPanel.drawingParts.first { $0.0 == "⌘↩" }?.1,
            "attach to chat"
        )
        XCTAssertEqual(
            AnnotationHintPanel.videoRecordingParts.first { $0.0 == "⌘↩" }?.1,
            "attach to chat"
        )
    }

    func testVideoArmedAndSelectingHintsToggleBackWithCmdD() {
        XCTAssertEqual(
            AnnotationHintPanel.videoArmedParts.first { $0.0 == "⌘D" }?.1,
            "drawing"
        )
        XCTAssertEqual(
            AnnotationHintPanel.videoSelectingParts.first { $0.0 == "⌘D" }?.1,
            "drawing"
        )
    }
}
