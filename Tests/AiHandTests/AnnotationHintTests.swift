import XCTest
@testable import AiHand

final class AnnotationHintTests: XCTestCase {
    func testDrawingHintsIncludeCmdDVideoToggle() {
        let keys = AnnotationHintPanel.drawingParts.map(\.0)
        XCTAssertTrue(keys.contains("⌘D"), keys.joined(separator: ", "))
        XCTAssertTrue(keys.contains("Right-drag"), "right-drag video entry remains")
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
