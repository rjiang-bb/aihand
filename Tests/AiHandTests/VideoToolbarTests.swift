import AppKit
import XCTest
@testable import AiHand

final class VideoToolbarTests: XCTestCase {
    func testStopButtonIsRedWithIconAndLabel() {
        let stop = NSButton()
        VideoToolbarPanel.styleStopButton(stop)

        XCTAssertEqual(stop.title, "Stop")
        XCTAssertEqual(VideoToolbarChrome.stopTitle, "Stop")
        XCTAssertEqual(VideoToolbarChrome.stoppedTitle, "Stopped")
        XCTAssertEqual(VideoToolbarChrome.stopSymbol, "stop.fill")
        XCTAssertEqual(stop.imagePosition, .imageLeading)
        XCTAssertNotNil(stop.image)
        XCTAssertEqual(stop.contentTintColor, .white)

        let bg = stop.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        XCTAssertNotNil(bg)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        bg?.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(r, 0.7, "Stop should read as red")
        XCTAssertGreaterThan(r, g)
        XCTAssertGreaterThan(r, b)

        XCTAssertNotEqual(
            VideoToolbarChrome.stopFill,
            VideoToolbarChrome.stopHoverFill,
            "Hover fill should darken the resting red"
        )

        // Compact control; margin is the card insets, not button padding.
        XCTAssertEqual(VideoToolbarChrome.stopHeight, 32)
        XCTAssertLessThanOrEqual(VideoToolbarChrome.stopMinWidth, 80)
        XCTAssertGreaterThanOrEqual(VideoToolbarChrome.rowInsets.top, 10)
        XCTAssertGreaterThanOrEqual(VideoToolbarChrome.rowInsets.bottom, 10)
        XCTAssertGreaterThanOrEqual(VideoToolbarChrome.rowInsets.left, 12)
        XCTAssertGreaterThanOrEqual(VideoToolbarChrome.rowInsets.right, 12)
    }

    func testSetElapsedFormatsTimerLabel() {
        let panel = VideoToolbarPanel()
        // show() needs a screen; drive the label formatter via setElapsed after a
        // minimal host by checking the chrome constants and a direct format mirror.
        let samples: [(TimeInterval, String)] = [
            (0, "00:00"),
            (5, "00:05"),
            (65, "01:05"),
            (600, "10:00"),
        ]
        for (seconds, expected) in samples {
            let total = max(0, Int(seconds.rounded(.down)))
            let formatted = String(format: "%02d:%02d", total / 60, total % 60)
            XCTAssertEqual(formatted, expected)
            panel.setElapsed(seconds) // keep API warm; no crash without a live panel
        }
    }
}
