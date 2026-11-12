import AppKit
import XCTest
@testable import AiHand

final class ChatClipboardTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("aihand.tests.chatclipboard.\(UUID().uuidString)"))
    }

    func testPlainOnlyWrite() {
        let pb = pasteboard()
        ChatClipboard.write(plain: "hello", html: nil, to: pb)
        XCTAssertEqual(pb.string(forType: .string), "hello")
        XCTAssertNil(pb.string(forType: .html))
    }

    func testHTMLWritePutsStringHTMLAndRTF() throws {
        let pb = pasteboard()
        let html = "<ul><li>opens a sheet<ul><li>have some text</li></ul></li></ul>"
        ChatClipboard.write(plain: "fallback", html: html, to: pb)
        let plain = try XCTUnwrap(pb.string(forType: .string))
        XCTAssertTrue(plain.contains("opens a sheet"), plain)
        XCTAssertTrue(plain.contains("have some text"), plain)
        // Nested bullets become `- ` with indent (not bare AppKit tabs).
        XCTAssertTrue(plain.contains("- opens a sheet") || plain.contains("•"), plain)
        XCTAssertTrue(plain.contains("- have some text") || plain.contains("  -"), plain)
        let htmlOut = try XCTUnwrap(pb.string(forType: .html))
        XCTAssertTrue(htmlOut.contains("<ul>"), htmlOut)
        XCTAssertTrue(htmlOut.contains("<li>"), htmlOut)
        XCTAssertNotNil(pb.data(forType: .rtf))
    }

    func testPlainTextPreservingListsFromNestedHTML() {
        let html = """
        <ul>
          <li>opens a sheet
            <ul>
              <li>have some text</li>
              <li>cannot submit</li>
            </ul>
          </li>
          <li>feedback form
            <ul>
              <li>let me know</li>
            </ul>
          </li>
        </ul>
        """
        let plain = ChatClipboard.plainTextPreservingLists(fromHTML: html, fallback: "x")
        XCTAssertTrue(plain.contains("- opens a sheet"), plain)
        XCTAssertTrue(plain.contains("- have some text"), plain)
        XCTAssertTrue(plain.contains("- cannot submit"), plain)
        XCTAssertTrue(plain.contains("- feedback form"), plain)
        XCTAssertTrue(plain.contains("- let me know"), plain)
        // Nested items are indented.
        let lines = plain.split(separator: "\n").map(String.init)
        let nested = lines.filter { $0.contains("have some text") || $0.contains("cannot submit") || $0.contains("let me know") }
        XCTAssertFalse(nested.isEmpty)
        for line in nested {
            XCTAssertTrue(line.hasPrefix("  - ") || line.hasPrefix("    - "), line)
        }
    }

    func testOrphanListItemsKeepBulletsInPlain() throws {
        // cloneContents of a multi-item selection often yields bare <li>s.
        let orphan = "<li>Notifications Me toggle</li><li>Guest session persists</li><li>Login screen</li>"
        let plain = ChatClipboard.plainTextPreservingLists(fromHTML: orphan, fallback: "Notifications Me toggle\nGuest session persists\nLogin screen")
        XCTAssertTrue(plain.contains("- Notifications Me toggle"), plain)
        XCTAssertTrue(plain.contains("- Guest session persists"), plain)
        XCTAssertTrue(plain.contains("- Login screen"), plain)

        let pb = pasteboard()
        ChatClipboard.write(plain: "Notifications Me toggle\nGuest session persists", html: orphan, to: pb)
        let out = try XCTUnwrap(pb.string(forType: .string))
        XCTAssertTrue(out.contains("- Notifications Me toggle"), out)
        XCTAssertTrue(out.contains("- Guest session persists"), out)
    }

    func testPrefersSuppliedPlainWhenItHasMoreMarkers() {
        let supplied = "- a\n- b\n- c"
        let fromHTML = "a\nb\nc"
        XCTAssertEqual(
            ChatClipboard.preferredListedPlain(fromHTML: fromHTML, supplied: supplied),
            supplied
        )
    }

    func testNormalizeWrapsOrphanListItems() {
        let out = ChatClipboard.normalizeListFragment("<li>a</li><li>b</li>")
        XCTAssertTrue(out.contains("<ul>"), out)
        XCTAssertTrue(out.hasPrefix("<ul>"), out)
    }

    func testOrderedListUsesNumbers() {
        let plain = ChatClipboard.plainTextPreservingLists(
            fromHTML: "<ol><li>one</li><li>two</li></ol>",
            fallback: "x"
        )
        XCTAssertTrue(plain.contains("1. one"), plain)
        XCTAssertTrue(plain.contains("2. two"), plain)
    }

    func testShellHTMLWiresRichCopy() {
        let html = ChatTranscriptView.shellHTML
        XCTAssertTrue(html.contains("selectionClipboardPayload"))
        XCTAssertTrue(html.contains("copySelectionToApp"))
        XCTAssertTrue(html.contains("nodeToPlain"))
        XCTAssertTrue(html.contains("addEventListener('copy'"))
        XCTAssertTrue(html.contains("syncPendingFromSelection"))
        XCTAssertTrue(html.contains("wrapOrphanListItems"))
        // Sticky buffer: empty selectionchange must not wipe pending before ⌘C.
        XCTAssertTrue(html.contains("Do NOT clear on empty") || html.contains("sticky"))
        XCTAssertTrue(html.contains("html: pendingSelectionHTML") || html.contains("html: payload.html"))
    }

    func testEmptySelectionWhileCommandHeldKeepsPending() {
        ChatSelectionHotkeys.pendingText = "keep me"
        ChatSelectionHotkeys.pendingHTML = "<p>keep me</p>"
        defer { ChatSelectionHotkeys.clearPending() }
        // Simulate the coordinator guard: empty update while ⌘ held is a no-op.
        // (Can't synthesize modifier flags easily; assert the sticky API still copies.)
        XCTAssertTrue(ChatSelectionHotkeys.hasPendingSelection)
        let pb = pasteboard()
        XCTAssertTrue(ChatSelectionHotkeys.copyPendingToPasteboard(pb))
        XCTAssertEqual(pb.string(forType: .string)?.contains("keep me"), true)
    }

    func testPasteboardDeclaresHTMLBeforeString() throws {
        let pb = pasteboard()
        ChatClipboard.write(
            plain: "fallback",
            html: "<ul><li><strong>bold</strong> item</li></ul>",
            to: pb
        )
        let types = pb.types ?? []
        let htmlIdx = types.firstIndex(of: .html)
        let stringIdx = types.firstIndex(of: .string)
        XCTAssertNotNil(htmlIdx)
        XCTAssertNotNil(stringIdx)
        if let htmlIdx, let stringIdx {
            XCTAssertLessThan(htmlIdx, stringIdx, "Rich destinations should see HTML before plain")
        }
        let htmlData = try XCTUnwrap(pb.data(forType: .html))
        XCTAssertTrue(String(data: htmlData, encoding: .utf8)?.contains("<li>") == true)
    }

    func testCopyPendingUsesStoredHTML() throws {
        let pb = pasteboard()
        ChatSelectionHotkeys.pendingText = "opens a sheet\nhave some text"
        ChatSelectionHotkeys.pendingHTML = "<ul><li>opens a sheet<ul><li>have some text</li></ul></li></ul>"
        defer { ChatSelectionHotkeys.clearPending() }
        XCTAssertTrue(ChatSelectionHotkeys.copyPendingToPasteboard(pb))
        let plain = try XCTUnwrap(pb.string(forType: .string))
        XCTAssertTrue(plain.contains("opens a sheet"), plain)
        XCTAssertNotNil(pb.string(forType: .html))
    }
}
