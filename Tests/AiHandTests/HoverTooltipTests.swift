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

    func testTipPrefersAboveControl() {
        let control = CGRect(x: 100, y: 80, width: 120, height: 28)
        let tip = NSSize(width: 140, height: 24)
        let visible = CGRect(x: 0, y: 0, width: 800, height: 600)
        let origin = HoverTooltipPlacement.origin(
            tipSize: tip, controlOnScreen: control, visibleFrame: visible)
        XCTAssertEqual(origin.y, control.maxY + HoverTooltipPlacement.gap)
        XCTAssertEqual(origin.x, control.midX - tip.width / 2)
    }

    func testTipFallsBackBelowWhenNoRoomAbove() {
        let control = CGRect(x: 100, y: 560, width: 120, height: 28)
        let tip = NSSize(width: 140, height: 24)
        let visible = CGRect(x: 0, y: 0, width: 800, height: 600)
        let origin = HoverTooltipPlacement.origin(
            tipSize: tip, controlOnScreen: control, visibleFrame: visible)
        XCTAssertEqual(origin.y, control.minY - tip.height - HoverTooltipPlacement.gap)
    }

    func testTipLevelStaysAboveOwnerWindows() {
        let sessions = NSWindow.Level.floating.rawValue + 2
        let settings = SettingsWindow.windowLevel
        let annotate = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)

        XCTAssertGreaterThan(HoverTooltipLevel.base.rawValue, sessions)
        XCTAssertGreaterThan(HoverTooltipLevel.base.rawValue, settings.rawValue)
        XCTAssertGreaterThan(
            HoverTooltipLevel.above(annotate).rawValue,
            annotate.rawValue + 1,
            "tips must clear an NSMenu that AppKit parks at owner+1"
        )
        XCTAssertGreaterThan(
            HoverTooltipLevel.above(annotate).rawValue,
            NSWindow.Level.popUpMenu.rawValue
        )
        XCTAssertEqual(
            HoverTooltipLevel.above(NSWindow.Level(rawValue: HoverTooltipLevel.base.rawValue - 10)).rawValue,
            max(HoverTooltipLevel.base.rawValue, NSWindow.Level.popUpMenu.rawValue + 1)
        )
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
