import XCTest
@testable import AiHand

final class SoftChromeCardEdgeTests: XCTestCase {
    func testEdgePresetsMatchPickerRadius() {
        XCTAssertEqual(SoftChromeCardEdge.square, SoftChromeCardEdge(top: 0, bottom: 0))
        XCTAssertEqual(SoftChromeCardEdge.topOfCard.top, SoftChrome.pickerCornerRadius)
        XCTAssertEqual(SoftChromeCardEdge.topOfCard.bottom, 0)
        XCTAssertEqual(SoftChromeCardEdge.bottomOfCard.bottom, SoftChrome.pickerCornerRadius)
        XCTAssertEqual(SoftChromeCardEdge.bottomOfCard.top, 0)
        XCTAssertEqual(SoftChromeCardEdge.fullCard.top, SoftChrome.pickerCornerRadius)
        XCTAssertEqual(SoftChromeCardEdge.fullCard.bottom, SoftChrome.pickerCornerRadius)
    }

    func testInsetAccumulatesWithoutChangingRadii() {
        let inset = SoftChromeCardEdge.bottomOfCard.inset(by: 1.5).inset(by: 0.5)
        XCTAssertEqual(inset.top, 0)
        XCTAssertEqual(inset.bottom, SoftChrome.pickerCornerRadius)
        XCTAssertEqual(inset.insetAmount, 2)
    }

    func testPathHugsFullBoundsWhenSquare() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        let path = SoftChromeCardEdge.square.path(in: rect)
        XCTAssertEqual(path.boundingRect, rect)
    }
}
