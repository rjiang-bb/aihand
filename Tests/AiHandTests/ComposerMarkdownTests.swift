import AppKit
import XCTest
@testable import AiHand

/// Headless checks on the composer's markdown logic (no window / real keystrokes).
/// Real-keystroke and layout checks live in `ComposerProbe` (`scripts/composer-probe.sh`).
final class ComposerMarkdownTests: XCTestCase {
    private func textView(_ text: String, caret: Int? = nil) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        tv.isEditable = true
        tv.isRichText = false
        tv.string = text
        tv.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        return tv
    }

    // MARK: quotes

    func testQuoteLineRanges() {
        let ns = "> a\nplain\n> b\n>> c\na > b" as NSString
        let lines = ComposerMarkdownStyler.quoteLineRanges(in: ns).map { ns.substring(with: $0) }
        XCTAssertEqual(lines, ["> a", "> b", ">> c"])
    }

    func testQuoteRangesSkipFences() {
        let ns = "```\n> not a quote\n```\n> real" as NSString
        let lines = ComposerMarkdownStyler.quoteLineRanges(in: ns).map { ns.substring(with: $0) }
        XCTAssertEqual(lines, ["> real"])
    }

    func testQuoteEnterContinuesAndExits() {
        let tv = textView("> hello")
        XCTAssertTrue(ComposerMarkdownStyler.handleQuoteEnter(in: tv))
        XCTAssertEqual(tv.string, "> hello\n> ")
        XCTAssertTrue(ComposerMarkdownStyler.handleQuoteEnter(in: tv))
        XCTAssertEqual(tv.string, "> hello\n")
    }

    func testQuoteBackspaceUnquotesWholePrefix() {
        let tv = textView("> hello\n> world", caret: 10)
        XCTAssertTrue(ComposerMarkdownStyler.handleQuoteBackspace(in: tv))
        XCTAssertEqual(tv.string, "> hello\nworld")

        let empty = textView("> a\n> ")
        XCTAssertTrue(ComposerMarkdownStyler.handleQuoteBackspace(in: empty))
        XCTAssertEqual(empty.string, "> a\n")
    }

    func testQuoteBackspaceIgnoresBodyAndNonQuotes() {
        XCTAssertFalse(ComposerMarkdownStyler.handleQuoteBackspace(in: textView("> hello")))
        XCTAssertFalse(ComposerMarkdownStyler.handleQuoteBackspace(in: textView("plain", caret: 3)))
        XCTAssertFalse(ComposerMarkdownStyler.handleQuoteBackspace(in: textView("```\n> x\n```", caret: 7)))
    }

    // MARK: lists

    func testListEnterContinuesBulletAndExitsOnEmpty() {
        let tv = textView("- one")
        XCTAssertTrue(ComposerMarkdownStyler.handleListEnter(in: tv))
        XCTAssertEqual(tv.string, "- one\n- ")
        XCTAssertTrue(ComposerMarkdownStyler.handleListEnter(in: tv))
        XCTAssertFalse(tv.string.hasSuffix("- "), tv.string)
    }

    func testOrderedListContinuesWithNextNumber() {
        let tv = textView("1. one")
        XCTAssertTrue(ComposerMarkdownStyler.handleListEnter(in: tv))
        XCTAssertEqual(tv.string, "1. one\n2. ")
    }

    func testListIndentAndOutdent() {
        let tv = textView("- a\n- b")
        XCTAssertTrue(ComposerMarkdownStyler.handleListIndent(in: tv))
        XCTAssertEqual(tv.string, "- a\n    - b")
        XCTAssertTrue(ComposerMarkdownStyler.handleListOutdent(in: tv))
        XCTAssertEqual(tv.string, "- a\n- b")
    }

    func testListBackspaceUnlists() {
        let tv = textView("- ", caret: 2)
        XCTAssertTrue(ComposerMarkdownStyler.handleListBackspace(in: tv))
        XCTAssertEqual(tv.string, "")
    }

    func testFancyBulletsNormalizeBackToDash() {
        let storage = NSTextStorage(string: "• one\n    ◦ two\n- three")
        ComposerMarkdownStyler.normalizeListMarkers(in: storage)
        XCTAssertEqual(storage.string, "- one\n    - two\n- three")
    }

    func testBulletSitesIgnoreFences() {
        let ns = "```\n- x\n```\n- y" as NSString
        let sites = ComposerMarkdownStyler.unorderedListBulletSites(in: ns)
        XCTAssertEqual(sites.count, 1)
    }

    // MARK: fences

    func testFenceEnterInsertsClosingFence() {
        let tv = textView("```swift")
        _ = ComposerMarkdownStyler.handleFenceEnter(in: tv)
        XCTAssertTrue(tv.string.hasPrefix("```swift\n"))
    }

    // MARK: URLs

    func testAutolinkURLResolution() {
        XCTAssertEqual(
            ComposerMarkdownStyler.url(fromAutolinkToken: "https://example.com/a")?.absoluteString,
            "https://example.com/a"
        )
        XCTAssertEqual(
            ComposerMarkdownStyler.url(fromAutolinkToken: "www.example.com")?.absoluteString,
            "https://www.example.com"
        )
        XCTAssertNil(ComposerMarkdownStyler.url(fromAutolinkToken: "not a url"))
    }

    func testAutolinksAreBlueWithoutUnderline() {
        let storage = NSTextStorage(string: "see https://example.com/x and www.foo.com done")
        ComposerMarkdownStyler.apply(to: storage, darkChrome: true, caret: nil, selection: nil)
        let ns = storage.string as NSString
        let httpsLoc = ns.range(of: "https://example.com/x").location
        let wwwLoc = ns.range(of: "www.foo.com").location
        XCTAssertNotEqual(httpsLoc, NSNotFound)
        XCTAssertNotEqual(wwwLoc, NSNotFound)

        let httpsUnderline = storage.attribute(.underlineStyle, at: httpsLoc, effectiveRange: nil) as? Int ?? 0
        XCTAssertEqual(httpsUnderline, 0, "composer links must not underline")
        let httpsURL = storage.attribute(
            ComposerMarkdownStyler.linkURLAttribute, at: httpsLoc, effectiveRange: nil
        ) as? String
        XCTAssertEqual(httpsURL, "https://example.com/x")

        let wwwURL = storage.attribute(
            ComposerMarkdownStyler.linkURLAttribute, at: wwwLoc, effectiveRange: nil
        ) as? String
        XCTAssertEqual(wwwURL, "https://www.foo.com")

        // Inside a fence, URLs stay plain code — no link attr.
        let fenced = NSTextStorage(string: "```\nhttps://nope.com\n```")
        ComposerMarkdownStyler.apply(to: fenced, darkChrome: true, caret: nil, selection: nil)
        let nope = (fenced.string as NSString).range(of: "https://nope.com").location
        XCTAssertNil(
            fenced.attribute(ComposerMarkdownStyler.linkURLAttribute, at: nope, effectiveRange: nil)
        )
    }
}
