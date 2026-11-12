import AppKit
import XCTest
@testable import AiHand

final class DrawingPointerParkTests: XCTestCase {
    override func tearDown() {
        DrawingPointerPark.unpark(warpToLogical: false)
        super.tearDown()
    }

    func testParkAppliesDeltasInAppKitSpace() {
        let start = CGPoint(x: 400, y: 300)
        DrawingPointerPark.park(at: start)
        XCTAssertTrue(DrawingPointerPark.isParked)
        XCTAssertEqual(DrawingPointerPark.pointerLocation, start)

        // Quartz-style delta: +y is down → AppKit y decreases.
        DrawingPointerPark.applyDelta(dx: 10, dy: 20)
        XCTAssertEqual(DrawingPointerPark.pointerLocation.x, 410, accuracy: 0.01)
        XCTAssertEqual(DrawingPointerPark.pointerLocation.y, 280, accuracy: 0.01)
    }

    func testUnparkClearsParkedFlag() {
        DrawingPointerPark.park(at: CGPoint(x: 100, y: 100))
        DrawingPointerPark.unpark(warpToLogical: false)
        XCTAssertFalse(DrawingPointerPark.isParked)
    }

    func testDeltasIgnoredWhenNotParked() {
        DrawingPointerPark.unpark(warpToLogical: false)
        let before = DrawingPointerPark.pointerLocation
        DrawingPointerPark.applyDelta(dx: 50, dy: 50)
        XCTAssertEqual(DrawingPointerPark.pointerLocation, before)
    }

    func testFollowCGEventLocationConvertsToAppKit() {
        let primaryH = NSScreen.screens.first?.frame.height ?? 900
        DrawingPointerPark.park(at: CGPoint(x: 10, y: 10))
        DrawingPointerPark.followCGEventLocation(CGPoint(x: 200, y: 100))
        XCTAssertEqual(DrawingPointerPark.pointerLocation.x, 200, accuracy: 0.01)
        XCTAssertEqual(DrawingPointerPark.pointerLocation.y, primaryH - 100, accuracy: 0.01)
    }
}
