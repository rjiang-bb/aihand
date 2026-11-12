import AppKit
import XCTest
@testable import AiHand

final class ComposerFieldEditorTests: XCTestCase {
    func testPromptTextViewFindsComposerInHierarchy() {
        let root = NSView(frame: .zero)
        let mid = NSView(frame: .zero)
        let prompt = ComposerPromptTextView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        root.addSubview(mid)
        mid.addSubview(prompt)
        XCTAssertTrue(ComposerFieldEditor.promptTextView(in: root) === prompt)
        XCTAssertNil(ComposerFieldEditor.promptTextView(in: NSView(frame: .zero)))
    }
}
