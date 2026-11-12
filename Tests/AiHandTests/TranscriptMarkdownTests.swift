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
        // marked is injected into shellHTML before `esc`; load it so configureMarked can bind.
        let markedStart = try XCTUnwrap(
            html.range(of: "marked v15"),
            "shellHTML must embed vendored marked.min.js"
        )
        // Walk back to the opening `/**` comment of the UMD bundle.
        let pre = html[..<markedStart.lowerBound]
        let commentOpen = try XCTUnwrap(pre.range(of: "/**", options: .backwards))
        let markedEnd = try XCTUnwrap(html.range(of: "</script>", range: markedStart.upperBound..<html.endIndex))
        let markedJS = String(html[commentOpen.lowerBound..<markedEnd.lowerBound])
        ctx.evaluateScript(markedJS)
        XCTAssertNil(jsError, "marked failed to load: \(jsError ?? "")")
        XCTAssertNotNil(ctx.objectForKeyedSubscript("marked"), "marked global missing after load")
        jsError = nil
        ctx.evaluateScript(js)
        XCTAssertNil(jsError, "transcript JS failed to load: \(jsError ?? "")")
    }

    private func md(_ s: String) -> String {
        ctx.objectForKeyedSubscript("markdownToHTML").call(withArguments: [s])?.toString() ?? ""
    }

    func testEmptyInput() { XCTAssertEqual(md(""), "") }

    func testEscapesHTML() {
        let out = md("<script>alert(1)</script>")
        XCTAssertFalse(out.contains("<script>"), out)
        XCTAssertTrue(out.contains("&lt;script&gt;"), out)
    }

    func testInlineHTMLIsEscapedNotRendered() {
        let out = md("hi <b>bold</b> there")
        XCTAssertFalse(out.contains("<b>bold</b>"), out)
        XCTAssertTrue(out.contains("&lt;b&gt;"), out)
        XCTAssertTrue(out.contains("hi "), out)
    }

    func testFootnotesNotRendered() {
        let out = md("See note[^1].\n\n[^1]: hidden detail")
        XCTAssertFalse(out.contains("footnotes"), out)
        XCTAssertFalse(out.contains("footnote-ref"), out)
        // Footnote marker stays literal / non-linked prose — not a ref UI.
        XCTAssertFalse(out.contains("href=\"#fn"), out)
    }

    func testStrikethroughAndTaskList() {
        let strike = md("~~gone~~")
        XCTAssertTrue(strike.contains("<del>"), strike)
        let task = md("- [ ] todo\n- [x] done")
        XCTAssertTrue(task.contains("type=\"checkbox\""), task)
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

    func testGFMTableRendersHTMLTable() {
        let src = """
        | Path | Role |
        |------|------|
        | `src/app/` | Expo Router |
        | src/game/ | Match logic |
        """
        let out = md(src)
        XCTAssertTrue(out.contains("<table>"), out)
        XCTAssertTrue(out.contains("<thead>"), out)
        XCTAssertTrue(out.contains("<th"), out)
        XCTAssertTrue(out.contains("<td"), out)
        XCTAssertTrue(out.contains("<code>src/app/</code>"), out)
        XCTAssertTrue(out.contains("Match logic"), out)
        XCTAssertFalse(out.contains("|------|"), "separator must not leak as text: \(out)")
    }

    func testGFMTableAlignment() {
        let out = md("| A | B |\n|:---|---:|\n| L | R |")
        // marked emits HTML align=; CSS maps it to text-align.
        XCTAssertTrue(out.contains("align=\"left\""), out)
        XCTAssertTrue(out.contains("align=\"right\""), out)
        let css = ChatTranscriptView.shellHTML
        XCTAssertTrue(css.contains("th[align=\"left\"]") || css.contains("th[align=left]"), css)
    }

    func testPipeLineWithoutSeparatorIsNotATable() {
        let out = md("| not a table |")
        XCTAssertFalse(out.contains("<table>"), out)
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

    func testToolDisclosureChevronHiddenUntilHoverOrExpanded() {
        let html = ChatTranscriptView.shellHTML
        // Idle: chevron invisible; hover or open keeps it visible.
        XCTAssertTrue(html.contains(".msg.tool-group .chev"))
        XCTAssertTrue(html.contains("opacity: 0;"))
        XCTAssertTrue(html.contains(".msg.tool-group .tool-summary:hover .chev"))
        XCTAssertTrue(html.contains(".msg.tool-group.expanded .chev"))
        XCTAssertTrue(html.contains("opacity: 0.9;"))
    }

    func testTranscriptUsesMonochromeOutlineGlyphsNotEmoji() {
        let html = ChatTranscriptView.shellHTML
        XCTAssertTrue(html.contains("function outlineGlyph("))
        XCTAssertTrue(html.contains("stroke=\"currentColor\""))
        XCTAssertFalse(html.contains("✏️"))
        XCTAssertFalse(html.contains("📄"))
        XCTAssertFalse(html.contains("💭"))
        XCTAssertTrue(html.contains("outlineGlyph('edit')"))
        XCTAssertTrue(html.contains("outlineGlyph('think')"))
    }

    func testWorkedChipNestsThoughtAndToolsUnderDisclosure() {
        let html = ChatTranscriptView.shellHTML
        XCTAssertTrue(html.contains("worked-group"))
        XCTAssertTrue(html.contains("workedGroupHTML"))
        XCTAssertTrue(html.contains("isWorkedChip"))
        XCTAssertTrue(html.contains("isThoughtChip"))
        // Same hover/expanded chevron treatment as tool groups.
        XCTAssertTrue(html.contains(".msg.worked-group .tool-summary:hover .chev"))
        XCTAssertTrue(html.contains(".msg.worked-group.expanded .chev"))
    }

    func testEditedFilesDisclosureCollapsedByDefault() {
        let html = ChatTranscriptView.shellHTML
        XCTAssertTrue(html.contains("edits-group"))
        XCTAssertTrue(html.contains("editsGroupHTML"))
        XCTAssertTrue(html.contains("diff-add"))
        XCTAssertTrue(html.contains("diff-del"))
        XCTAssertTrue(html.contains("inProgress ? 'Editing' : 'Edited'"))
        XCTAssertTrue(html.contains(".msg.edits-group .tool-summary:hover .chev"))
        // Live footer colors +/- the same way.
        XCTAssertTrue(html.contains("diff-add"))
        XCTAssertTrue(html.contains("liveActivityHTML"))
        // Default is collapsed — expanded only when __expandedGroups remembers it.
        XCTAssertTrue(html.contains("!!window.__expandedGroups[groupId]"))
    }
}
