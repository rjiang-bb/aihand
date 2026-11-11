import AppKit
import XCTest
@testable import AiHand

final class PointerCursorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PointerCursor.resetForTests()
    }

    override func tearDown() {
        PointerCursor.resetForTests()
        super.tearDown()
    }

    func testNestingPushPop() {
        XCTAssertEqual(PointerCursor.nestingDepthForTests, 0)
        PointerCursor.setHovering(true)
        PointerCursor.setHovering(true)
        XCTAssertEqual(PointerCursor.nestingDepthForTests, 2)
        PointerCursor.setHovering(false)
        XCTAssertEqual(PointerCursor.nestingDepthForTests, 1)
        PointerCursor.setHovering(false)
        XCTAssertEqual(PointerCursor.nestingDepthForTests, 0)
    }

    func testExtraPopIsIgnored() {
        PointerCursor.setHovering(false)
        XCTAssertEqual(PointerCursor.nestingDepthForTests, 0)
        PointerCursor.setHovering(true)
        PointerCursor.setHovering(false)
        PointerCursor.setHovering(false)
        XCTAssertEqual(PointerCursor.nestingDepthForTests, 0)
    }
}

final class PreviewCursorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PreviewCursor.resetForTests()
    }

    override func tearDown() {
        PreviewCursor.resetForTests()
        super.tearDown()
    }

    func testNestingPushPop() {
        XCTAssertEqual(PreviewCursor.nestingDepthForTests, 0)
        PreviewCursor.setHovering(true)
        PreviewCursor.setHovering(true)
        XCTAssertEqual(PreviewCursor.nestingDepthForTests, 2)
        PreviewCursor.setHovering(false)
        PreviewCursor.setHovering(false)
        XCTAssertEqual(PreviewCursor.nestingDepthForTests, 0)
    }
}

final class OpenHandCursorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OpenHandCursor.resetForTests()
    }

    override func tearDown() {
        OpenHandCursor.resetForTests()
        super.tearDown()
    }

    func testNestingPushPop() {
        XCTAssertEqual(OpenHandCursor.nestingDepthForTests, 0)
        OpenHandCursor.setHovering(true)
        OpenHandCursor.setHovering(true)
        XCTAssertEqual(OpenHandCursor.nestingDepthForTests, 2)
        OpenHandCursor.setHovering(false)
        OpenHandCursor.setHovering(false)
        XCTAssertEqual(OpenHandCursor.nestingDepthForTests, 0)
    }
}
