import XCTest
import JavaScriptCore
@testable import AiHand

/// Runs the transcript's real `markdownToHTML` (extracted from the shell HTML) in JavaScriptCore.
final class TranscriptMarkdownTests: XCTestCase {
    private var ctx: JSContext!

    override func setUpWithError() throws {
        let html = ChatTranscriptView.shellHTML
        let start = try XCTUnwrap(html.range(of: "function esc("))
        let end = try XCTUnwrap(html.range(of: "function toolGlyph("))
        let js = String(html[start.lowerBound..<end.lowerBound])
        ctx = JSContext()
        var jsError: String?
        ctx.exceptionHandler = { _, e in jsError = e?.toString() }
        ctx.evaluateScript(js)
        XCTAssertNil(jsError, "transcript JS failed to load: \(jsError ?? "")")
    }

    private func md(_ s: String) -> String {
        ctx.objectForKeyedSubscript("markdownToHTML").call(withArguments: [s])?.toString() ?? ""
    }

    func testEmptyInput() { XCTAssertEqual(md(""), "") }

    func testEscapesHTML() {
        XCTAssertFalse(md("<script>alert(1)</script>").contains("<script>"))
    }

    func testInlineFormatting() {
        let out = md("a `code` **bold** *it* [x](https://e.com)")
        XCTAssertTrue(out.contains("<code>code</code>"))
        XCTAssertTrue(out.contains("<strong>bold</strong>"))
        XCTAssertTrue(out.contains("<em>it</em>"))
        XCTAssertTrue(out.contains("href=\"https://e.com\""))
    }

    func testBareURLIsAutolinked() {
        XCTAssertTrue(md("see https://example.com/a.").contains("<a href=\"https://example.com/a\""))
    }

    func testFlatBulletList() {
        let out = md("- one\n- two")
        XCTAssertEqual(out.components(separatedBy: "<li>").count - 1, 2)
        XCTAssertTrue(out.contains("<ul>"))
    }

    func testNestedListsNestInsideParentItem() {
        let out = md("- a\n    - b\n        - c\n- d")
        XCTAssertEqual(out.components(separatedBy: "<ul>").count - 1, 3, out)
        // The inner list must open before its parent <li> closes.
        let a = try! XCTUnwrap(out.range(of: "a"))
        let inner = try! XCTUnwrap(out.range(of: "<ul>", range: a.upperBound..<out.endIndex))
        let closeLi = try! XCTUnwrap(out.range(of: "</li>", range: a.upperBound..<out.endIndex))
        XCTAssertLessThan(inner.lowerBound, closeLi.lowerBound, out)
    }

    func testOrderedListWithNestedBullets() {
        let out = md("1. one\n    - x\n2. two")
        XCTAssertTrue(out.contains("<ol"))
        XCTAssertTrue(out.contains("<ul>"))
    }

    func testOrderedListKeepsStartNumber() {
        XCTAssertTrue(md("3. c\n4. d").contains("start=\"3\""))
    }

    func testFencedCodeBlockIsNotMarkdownParsed() {
        let out = md("```swift\nlet a = **x**\n- not a list\n```")
        XCTAssertTrue(out.contains("<pre"))
        XCTAssertFalse(out.contains("<strong>"))
        XCTAssertFalse(out.contains("<li>"))
    }

    func testCodeBlockHasCopyButtonWithTooltip() {
        let out = md("```\nx\n```")
        XCTAssertTrue(out.contains("code-copy"))
        XCTAssertTrue(out.contains("Copy to clipboard"))
    }

    func testBlockquote() {
        XCTAssertTrue(md("> quoted").contains("<blockquote"))
    }

    func testCRLFNormalized() {
        XCTAssertEqual(md("- a\r\n- b").components(separatedBy: "<li>").count - 1, 2)
    }

    func testSteeredMarkerIsIconBesideContent() {
        let html = ChatTranscriptView.shellHTML
        XCTAssertTrue(html.contains("steer-row"), "icon sits left of the first line")
        XCTAssertTrue(html.contains("steer-icon"))
        XCTAssertFalse(html.contains("steer-badge"))
        XCTAssertFalse(html.contains("+ 'Steered</div>'"), "no visible Steered label")
    }

    func testSelectionToolbarButtonsHaveNoNativeTooltips() {
        let html = ChatTranscriptView.shellHTML
        XCTAssertTrue(html.contains("data-action=\"chat\""))
        XCTAssertTrue(html.contains("data-action=\"new\""))
        // Labels already show shortcuts — native `title` tooltips are redundant.
        XCTAssertFalse(html.contains("title=\"Add to chat"))
        XCTAssertFalse(html.contains("title=\"Add to new session"))
    }

    func testStatusChipAndLiveActivityMarkup() {
        let html = ChatTranscriptView.shellHTML
        XCTAssertTrue(html.contains(".msg.status"))
        XCTAssertTrue(html.contains("live-activity"))
        XCTAssertTrue(html.contains("live-spinner"))
        XCTAssertTrue(html.contains("live-spin"))
        XCTAssertTrue(html.contains("Exploring "))
        XCTAssertTrue(html.contains("liveActivityHTML"))
        // In-progress footer matches body text size (not the smaller muted caption).
        XCTAssertTrue(html.contains(".msg.live-activity") && html.contains("14.5px"))
    }
}
