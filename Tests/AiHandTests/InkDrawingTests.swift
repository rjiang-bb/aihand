import AppKit
import XCTest
@testable import AiHand

final class StrokePathTests: XCTestCase {
    private func box(_ tool: DrawTool, _ pts: [CGPoint], width: CGFloat = 4) -> CGRect {
        StrokePath.make(tool: tool, points: pts, lineWidth: width).boundingBoxOfPath
    }

    func testRectangleNormalizesAnyDragDirection() {
        let a = CGPoint(x: 10, y: 20), b = CGPoint(x: 110, y: 70)
        let expected = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(box(.rectangle, [a, b]), expected)
        XCTAssertEqual(box(.rectangle, [b, a]), expected, "dragging up-left gives the same rect")
        XCTAssertEqual(box(.rectangle, [CGPoint(x: 110, y: 20), CGPoint(x: 10, y: 70)]), expected)
    }

    func testRectangleWithSinglePointIsDegenerateNotCrashing() {
        XCTAssertEqual(box(.rectangle, [CGPoint(x: 5, y: 5)]).size, .zero)
    }

    func testEmptyPointsGiveEmptyPaths() {
        for tool in DrawTool.allCases {
            XCTAssertTrue(StrokePath.make(tool: tool, points: []).isEmpty, "\(tool)")
        }
    }

    func testTextToolHasNoStrokePath() {
        XCTAssertTrue(StrokePath.make(tool: .text, points: [.zero, CGPoint(x: 9, y: 9)]).isEmpty)
    }

    func testArrowIncludesShaftAndHeadReachingTheTip() {
        let o = CGPoint(x: 0, y: 0), tip = CGPoint(x: 100, y: 0)
        let b = box(.arrow, [o, tip])
        XCTAssertEqual(b.minX, 0, accuracy: 0.01)
        XCTAssertEqual(b.maxX, 100, accuracy: 0.01, "tip is the furthest point")
        XCTAssertGreaterThan(b.height, 4, "head wings extend off the shaft")
    }

    func testArrowHeadScalesWithLineWidth() {
        let thin = box(.arrow, [.zero, CGPoint(x: 200, y: 0)], width: 2)
        let thick = box(.arrow, [.zero, CGPoint(x: 200, y: 0)], width: 12)
        XCTAssertGreaterThan(thick.height, thin.height)
    }

    func testZeroLengthArrowDoesNotProduceNaN() {
        let b = box(.arrow, [CGPoint(x: 3, y: 3), CGPoint(x: 3, y: 3)])
        XCTAssertFalse(b.isNull || b.origin.x.isNaN || b.origin.y.isNaN)
    }

    func testFreehandPassesThroughAllPointsExtent() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 80), CGPoint(x: 100, y: 10)]
        let b = box(.freehand, pts)
        XCTAssertEqual(b.maxX, 100, accuracy: 0.01, "path ends at the last point")
        XCTAssertGreaterThan(b.height, 20)
        XCTAssertFalse(StrokePath.make(tool: .freehand, points: [CGPoint(x: 1, y: 1)]).isEmpty, "a dot still draws")
    }
}

final class InkTextStyleTests: XCTestCase {
    func testFontSizeAndPaddingScaleWithStroke() {
        XCTAssertEqual(InkTextStyle.fontSize(forStrokeWidth: 2), 13, "never below 13")
        XCTAssertEqual(InkTextStyle.fontSize(forStrokeWidth: 10), 30)
        XCTAssertEqual(InkTextStyle.padding(forFontSize: 13), 6)
        XCTAssertGreaterThan(InkTextStyle.padding(forFontSize: 60), 6)
        XCTAssertGreaterThanOrEqual(InkTextStyle.cornerRadius(forFontSize: 13), 6)
    }

    func testForegroundContrastsWithBackground() {
        func lum(_ c: CGColor) -> CGFloat { c.components?.prefix(3).reduce(0, +) ?? 0 }
        XCTAssertGreaterThan(lum(InkTextStyle.contrastingForeground(for: Ink.hex(0x1D1D21))), 2.5, "light text on dark")
        XCTAssertLessThan(lum(InkTextStyle.contrastingForeground(for: Ink.hex(0xF2B705))), 1, "dark text on yellow")
        XCTAssertGreaterThan(lum(InkTextStyle.contrastingForeground(for: Ink.purple)), 2.5)
    }

    func testBoxSizeGrowsWithTextAndLines() {
        let one = InkTextStyle.boxSize(for: "hi", fontSize: 16)
        let wide = InkTextStyle.boxSize(for: "hi there friend", fontSize: 16)
        let tall = InkTextStyle.boxSize(for: "hi\nthere\nfriend", fontSize: 16)
        XCTAssertGreaterThan(wide.width, one.width)
        XCTAssertGreaterThan(tall.height, one.height * 2)
        XCTAssertLessThan(tall.width, wide.width, "hard breaks grow height, not width")
    }

    func testLongLinesWrapAtMaxWidth() {
        let long = String(repeating: "word ", count: 80)
        let size = InkTextStyle.textSize(for: long, fontSize: 16, maxTextWidth: 300)
        XCTAssertLessThanOrEqual(size.width, 300.5)
        XCTAssertGreaterThan(size.height, InkTextStyle.textSize(for: "word", fontSize: 16).height * 2)
    }

    func testEmptyTextStillHasACaretSizedBox() {
        let s = InkTextStyle.textSize(for: "", fontSize: 20)
        XCTAssertGreaterThan(s.width, 0)
        XCTAssertGreaterThan(s.height, 0)
    }

    func testRenderImageMatchesBoxSize() {
        let img = InkTextStyle.renderImage(text: "Fix this", background: Ink.red, fontSize: 18)
        let box = InkTextStyle.boxSize(for: "Fix this", fontSize: 18)
        XCTAssertEqual(img.size.width, box.width, accuracy: 0.5)
        XCTAssertEqual(img.size.height, box.height, accuracy: 0.5)
    }
}

final class InkLifecycleTests: XCTestCase {
    func testFreehandStrokeLifecycle() throws {
        let ink = Ink()
        XCTAssertFalse(ink.isDrawing)
        ink.begin(at: CGPoint(x: 10, y: 10), width: 4)
        XCTAssertTrue(ink.isDrawing)
        for i in 1...10 { ink.extend(to: CGPoint(x: 10 + CGFloat(i) * 10, y: 10 + CGFloat(i) * 3)) }
        let result = try XCTUnwrap(ink.end())
        XCTAssertFalse(ink.isDrawing)
        XCTAssertEqual(result.tool, .freehand)
        XCTAssertEqual(result.points.count, 11)
        XCTAssertEqual(result.width, 4)
        XCTAssertTrue(result.bounds.contains(CGPoint(x: 60, y: 25)), "bounds cover the stroke")
        XCTAssertEqual(ink.layer.sublayers?.count, 1)
    }

    func testTinyMovementsAreIgnoredForFreehand() throws {
        let ink = Ink()
        ink.begin(at: .zero, width: 4)
        ink.extend(to: CGPoint(x: 0.5, y: 0.5))
        ink.extend(to: CGPoint(x: 1.0, y: 0.2))
        XCTAssertEqual(try XCTUnwrap(ink.end()).points.count, 1)
    }

    func testRectangleKeepsOnlyAnchorAndCurrentCorner() throws {
        let ink = Ink()
        ink.begin(at: CGPoint(x: 5, y: 5), width: 3, tool: .rectangle)
        ink.extend(to: CGPoint(x: 50, y: 20))
        ink.extend(to: CGPoint(x: 80, y: 60))
        let r = try XCTUnwrap(ink.end())
        XCTAssertEqual(r.tool, .rectangle)
        XCTAssertEqual(r.points, [CGPoint(x: 5, y: 5), CGPoint(x: 80, y: 60)])
    }

    func testArrowTool() throws {
        let ink = Ink()
        ink.begin(at: .zero, width: 3, tool: .arrow)
        ink.extend(to: CGPoint(x: 40, y: 40))
        XCTAssertEqual(try XCTUnwrap(ink.end()).tool, .arrow)
    }

    func testTextToolCannotBeginAStroke() {
        let ink = Ink()
        ink.begin(at: .zero, width: 3, tool: .text)
        XCTAssertFalse(ink.isDrawing)
        XCTAssertNil(ink.end())
        XCTAssertNil(ink.layer.sublayers)
    }

    func testExtendOrEndWithoutBeginIsANoOp() {
        let ink = Ink()
        ink.extend(to: CGPoint(x: 5, y: 5))
        XCTAssertNil(ink.end())
        XCTAssertNil(ink.layer.sublayers)
    }

    func testStrokesUseInkColorAndStayUntilCleared() throws {
        let ink = Ink()
        ink.color = Ink.red
        ink.begin(at: .zero, width: 4)
        ink.extend(to: CGPoint(x: 20, y: 20))
        let r = try XCTUnwrap(ink.end())
        XCTAssertEqual(r.color, Ink.red)
        XCTAssertTrue(ink.keep)
        XCTAssertNil(r.layer.animation(forKey: "fade"), "kept drawings never fade")
        ink.clear()
        XCTAssertTrue(ink.layer.sublayers?.isEmpty ?? true)
    }

    func testUndoRemovesNewestStrokeFirst() throws {
        let ink = Ink()
        var layers: [CALayer] = []
        for i in 0..<3 {
            ink.begin(at: CGPoint(x: CGFloat(i) * 30, y: 0), width: 3)
            ink.extend(to: CGPoint(x: CGFloat(i) * 30 + 20, y: 20))
            layers.append(try XCTUnwrap(ink.end()).layer)
        }
        XCTAssertTrue(ink.undoLast() === layers[2])
        XCTAssertTrue(ink.undoLast() === layers[1])
        XCTAssertEqual(ink.layer.sublayers?.count, 1)
        XCTAssertTrue(ink.undoLast() === layers[0])
        XCTAssertNil(ink.undoLast(), "nothing left to undo")
    }

    func testUndoWhileDraggingCancelsTheLiveStroke() {
        let ink = Ink()
        ink.begin(at: .zero, width: 3)
        ink.extend(to: CGPoint(x: 30, y: 30))
        XCTAssertNil(ink.undoLast(), "cancelling a live stroke returns no finished layer")
        XCTAssertFalse(ink.isDrawing)
        XCTAssertTrue(ink.layer.sublayers?.isEmpty ?? true)
    }

    func testTextAnnotation() throws {
        let ink = Ink()
        ink.color = Ink.hex(0x2F86F0)
        let r = try XCTUnwrap(ink.addText("  Fix padding \n", topLeft: CGPoint(x: 100, y: 300), fontSize: 18))
        XCTAssertEqual(r.tool, .text)
        XCTAssertEqual(r.text, "Fix padding", "trimmed")
        XCTAssertEqual(r.layer.frame.minX, 100, accuracy: 0.01)
        XCTAssertEqual(r.layer.frame.maxY, 300, accuracy: 0.01, "clicked top edge stays fixed (AppKit y-up)")
        XCTAssertNotNil(r.layer.contents)
        XCTAssertEqual(ink.layer.sublayers?.count, 1)
        XCTAssertTrue(ink.undoLast() === r.layer)
    }

    func testBlankTextIsRejected() {
        let ink = Ink()
        XCTAssertNil(ink.addText("   \n ", topLeft: .zero, fontSize: 18))
        XCTAssertNil(ink.layer.sublayers)
    }

    func testMixedToolsUndoInOrder() throws {
        let ink = Ink()
        ink.begin(at: .zero, width: 3); ink.extend(to: CGPoint(x: 10, y: 10)); _ = ink.end()
        let text = try XCTUnwrap(ink.addText("hi", topLeft: CGPoint(x: 50, y: 50), fontSize: 16))
        XCTAssertTrue(ink.undoLast() === text.layer)
        XCTAssertEqual(ink.layer.sublayers?.count, 1)
    }
}

final class PointerStyleTests: XCTestCase {
    func testBuiltInStylesHaveTitleAndInk() {
        for style in PointerStyle.builtInHands {
            XCTAssertFalse(style.title.isEmpty)
            XCTAssertNotNil(style.assetName)
            XCTAssertNotNil(style.inkColor.components)
        }
    }

    func testLaserIsSpecial() {
        XCTAssertEqual(PointerStyle.laser.title, "Laser dot")
        XCTAssertNil(PointerStyle.laser.assetName)
        XCTAssertEqual(PointerStyle.laser.inkColor, Ink.red)
        XCTAssertTrue(PointerStyle.allCases.contains(.laser))
    }

    func testRawValueRoundTripAndRejection() {
        for style in PointerStyle.allCases {
            XCTAssertEqual(PointerStyle(rawValue: style.rawValue), style)
        }
        XCTAssertNil(PointerStyle(rawValue: "not-a-hand"))
    }

    func testDefaultPinnedAreKnownStyles() {
        for style in PointerStyle.defaultPinned { XCTAssertTrue(PointerStyle.allCases.contains(style)) }
        XCTAssertEqual(PointerStyle.defaultPinned.last, .laser)
    }

    func testBuiltInIdsAreUnique() {
        let ids = PointerStyle.builtInHands.map(\.rawValue)
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}

final class DrawToolTests: XCTestCase {
    func testToolMetadata() {
        XCTAssertEqual(DrawTool.allCases.map(\.shortcut), ["F", "R", "A", "T"])
        XCTAssertEqual(Set(DrawTool.allCases.map(\.title)).count, 4)
        for t in DrawTool.allCases { XCTAssertFalse(t.symbol.isEmpty) }
    }

    func testToolAndThicknessPersistInSandbox() throws {
        let suite = "aihand.tests.\(UUID().uuidString)"
        let saved = Preferences.defaults
        Preferences.defaults = UserDefaults(suiteName: suite)!
        defer { Preferences.defaults.removePersistentDomain(forName: suite); Preferences.defaults = saved }
        XCTAssertEqual(Preferences.drawTool, .freehand, "default")
        for t in DrawTool.allCases {
            Preferences.drawTool = t
            XCTAssertEqual(Preferences.drawTool, t)
        }
        let widths = StrokeThickness.allCases.map(\.multiplier)
        XCTAssertEqual(widths, widths.sorted(), "thickness options increase")
    }
}

@MainActor
final class ArmViewInkTests: XCTestCase {
    func testInkWidthFollowsThicknessPreference() {
        let suite = "aihand.tests.\(UUID().uuidString)"
        let saved = Preferences.defaults
        Preferences.defaults = UserDefaults(suiteName: suite)!
        defer { Preferences.defaults.removePersistentDomain(forName: suite); Preferences.defaults = saved }
        let view = ArmView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        var last: CGFloat = 0
        for t in StrokeThickness.allCases {
            Preferences.strokeThickness = t
            XCTAssertGreaterThan(view.inkWidth, last - 0.0001)
            last = view.inkWidth
        }
        XCTAssertGreaterThanOrEqual(view.inkWidth, 1.5)
    }

    func testInkColorFollowsPointerStyle() {
        let view = ArmView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.setStyle(.coral)
        XCTAssertEqual(view.ink.color, Ink.red)
        view.setStyle(.laser)
        XCTAssertEqual(view.style, .laser)
        XCTAssertEqual(view.ink.color, Ink.red)
        view.setStyle(.plush)
        XCTAssertEqual(view.ink.color, PointerStyle.plush.inkColor)
    }
}
