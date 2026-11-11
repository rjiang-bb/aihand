import XCTest
@testable import AiHand

final class HoverTooltipTests: XCTestCase {
    func testIconLabelIncludesShortcut() {
        XCTAssertEqual(HoverTooltipLabel.icon("Settings", shortcut: "⌘,"), "Settings (⌘,)")
        XCTAssertEqual(HoverTooltipLabel.icon("Draw", shortcut: "⌘D"), "Draw (⌘D)")
    }

    func testIconLabelWithoutShortcut() {
        XCTAssertEqual(HoverTooltipLabel.icon("Remove"), "Remove")
        XCTAssertEqual(HoverTooltipLabel.icon("Preview", shortcut: "  "), "Preview")
    }
}

final class ComposerSendButtonIconTests: XCTestCase {
    func testSteerGlyphOnlyWhenCommandHeldInFollowUpPrompt() {
        XCTAssertEqual(
            ComposerSendButtonIcon.systemName(isFollowUp: true, commandHeld: true, promptFocused: true),
            "steeringwheel.circle.fill"
        )
        XCTAssertEqual(
            ComposerSendButtonIcon.systemName(isFollowUp: true, commandHeld: false, promptFocused: true),
            "arrow.up.circle.fill"
        )
        XCTAssertEqual(
            ComposerSendButtonIcon.systemName(isFollowUp: true, commandHeld: true, promptFocused: false),
            "arrow.up.circle.fill"
        )
        XCTAssertEqual(
            ComposerSendButtonIcon.systemName(isFollowUp: false, commandHeld: true, promptFocused: true),
            "arrow.up.circle.fill"
        )
    }
}
