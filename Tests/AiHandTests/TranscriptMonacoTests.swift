import AppKit
import WebKit
import XCTest
@testable import AiHand

/// Loads the real transcript shell in a WKWebView and mounts a Monaco diff through CodeView.
final class TranscriptMonacoTests: XCTestCase {
    private final class Nav: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }

    private var window: NSWindow!
    private var webView: WKWebView!
    private let nav = Nav()

    override func setUpWithError() throws {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 800), configuration: config)
        webView.navigationDelegate = nav
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        // Occluded windows throttle WebKit's render loop (Monaco paints gutters in rAF);
        // keep it frontmost but practically invisible.
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.level = .floating
        window.orderFrontRegardless()
        webView.loadHTMLString(ChatTranscriptView.shellHTML, baseURL: AssetSchemeHandler.baseURL)
        try wait("shell load") { self.nav.done }
        // The XCTest host has no display link, so rAF never fires and Monaco can't paint.
        _ = try eval("""
        window.requestAnimationFrame = function(cb) { return setTimeout(function() { cb(performance.now()); }, 16); };
        window.cancelAnimationFrame = function(id) { clearTimeout(id); };
        true
        """)
    }

    override func tearDown() {
        window.orderOut(nil)
        window = nil
        webView = nil
    }

    private func wait(_ label: String, timeout: TimeInterval = 20, _ cond: () -> Bool) throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTFail("timed out: \(label)")
        throw XCTSkip("timeout")
    }

    private func eval(_ js: String) throws -> Any? {
        var out: Any?
        var finished = false
        webView.evaluateJavaScript(js) { r, _ in out = r; finished = true }
        try wait("eval") { finished }
        return out
    }

    func testCodeViewMountsMonacoDiffWithLineNumbersAndModes() throws {
        XCTAssertEqual(try eval("typeof window.CodeView") as? String, "object")
        _ = try eval("""
        (function(){
          var host = document.createElement('div');
          host.id = 'probe';
          host.style.width = '600px';
          document.body.appendChild(host);
          window.__probe = CodeView.createDiff(host, {
            path: '/w/aihand/README.md',
            original: '# AiHand\\n\\nold line\\nkeep\\n',
            modified: '# AiHand\\n\\nnew line\\nkeep\\nadded\\n',
            added: 2, removed: 1, mode: 'inline'
          });
          return true;
        })()
        """)
        try wait("monaco diff editor") {
            ((try? self.eval("!!document.querySelector('#probe .monaco-diff-editor .view-lines')")) as? Bool) == true
        }
        try wait("diff computed") {
            ((try? self.eval("document.querySelectorAll('#probe .line-numbers').length")) as? Int ?? 0) > 0
        }
        XCTAssertEqual(try eval("window.monaco.editor.getModels()[1].getLanguageId()") as? String, "markdown")
        XCTAssertEqual(try eval("document.querySelector('#probe .cv-path').textContent") as? String, "/w/aihand/README.md")
        XCTAssertEqual(try eval("document.querySelector('#probe .cv-seg-btn.on').getAttribute('data-mode')") as? String, "inline")
        // Markdown files get a Preview toggle that uses the shared transcript renderer.
        XCTAssertEqual(try eval("!!document.querySelector('#probe .cv-preview-btn')") as? Bool, true)
        XCTAssertEqual(try eval("typeof window.AiHandMarkdown.toHTML") as? String, "function")
        _ = try eval("document.querySelector('#probe .cv-preview-btn').click(); true")
        try wait("markdown preview") {
            ((try? self.eval("document.querySelector('#probe .cv-body').classList.contains('cv-preview') && !!document.querySelector('#probe .cv-md h1')")) as? Bool) == true
        }
        XCTAssertEqual(try eval("document.querySelector('#probe .cv-preview-btn').classList.contains('on')") as? Bool, true)
        XCTAssertEqual(try eval("document.querySelector('#probe .cv-md h1').textContent") as? String, "AiHand")
        // Toggle back to the diff.
        _ = try eval("document.querySelector('#probe .cv-preview-btn').click(); true")
        try wait("diff restored") {
            ((try? self.eval("!document.querySelector('#probe .cv-body').classList.contains('cv-preview') && !!document.querySelector('#probe .monaco-diff-editor')")) as? Bool) == true
        }

        // Copy-path button swaps to a checkmark, then restores.
        let copyGlyph = try eval("document.querySelector('#probe .cv-icon-btn').innerHTML") as? String
        _ = try eval("document.querySelector('#probe .cv-icon-btn').click(); true")
        XCTAssertEqual(try eval("document.querySelector('#probe .cv-icon-btn').classList.contains('done')") as? Bool, true)
        XCTAssertNotEqual(try eval("document.querySelector('#probe .cv-icon-btn').innerHTML") as? String, copyGlyph)
        try wait("copy glyph restores") {
            ((try? self.eval("document.querySelector('#probe .cv-icon-btn').classList.contains('done')")) as? Bool) == false
        }
        XCTAssertEqual(try eval("document.querySelector('#probe .cv-icon-btn').innerHTML") as? String, copyGlyph)

        _ = try eval("window.__probe.setMode('side-by-side'); true")
        try wait("side-by-side renders original pane") {
            ((try? self.eval("document.querySelectorAll('#probe .editor.original .view-lines').length")) as? Int ?? 0) > 0
                && ((try? self.eval("document.querySelector('#probe .editor.original').offsetWidth")) as? Int ?? 0) > 0
        }
        _ = try eval("window.__probe.dispose(); true")
        XCTAssertEqual(try eval("window.monaco.editor.getModels().length") as? Int, 0)
    }

    func testInlineLineNumberColumnsLeaveAGap() throws {
        _ = try eval("""
        (function(){
          var host = document.createElement('div');
          host.id = 'gap';
          host.style.width = '600px';
          document.body.appendChild(host);
          var o = ''; for (var i = 1; i <= 400; i++) o += 'line ' + i + '\\n';
          window.__gap = CodeView.createDiff(host, {
            path: 'a.txt', original: o, modified: o.replace('line 200\\n', 'line 200 changed\\n'), mode: 'inline'
          });
          return true;
        })()
        """)
        try wait("diff editor") {
            ((try? self.eval("!!document.querySelector('#gap .monaco-diff-editor .view-lines')")) as? Bool) == true
        }
        // 3-digit numbers → columns are at least 4 chars wide (one digit of breathing room).
        XCTAssertEqual(
            try eval("window.__gap.editor.getModifiedEditor().getOption(window.monaco.editor.EditorOption.lineNumbersMinChars)") as? Int,
            4
        )
        _ = try eval("window.__gap.dispose(); true")
    }

    func testEditRowExpandsIntoFileDiffPlaceholder() throws {
        _ = try eval("""
        window.__expandedGroups = {};
        window.renderMessages([
          { id: 'u1', kind: 'user', text: 'go' },
          { id: '11111111-1111-1111-1111-111111111111', kind: 'tool', text: 'Edited aihand/README.md +6 -1', editSnapshot: true },
          { id: '22222222-2222-2222-2222-222222222222', kind: 'tool', text: 'Edited aihand/a.swift +1' }
        ], true, null);
        document.querySelector('.msg.edits-group .tool-summary').click();
        true
        """)
        XCTAssertEqual(try eval("document.querySelectorAll('.tool-detail.has-diff').length") as? Int, 1)
        _ = try eval("document.querySelector('.tool-detail.has-diff').click(); true")
        XCTAssertEqual(try eval("document.querySelectorAll('.file-diff[data-msg-id]').length") as? Int, 1)
        XCTAssertEqual(try eval("window.__liveDiff && window.__liveDiff.id") as? String,
                       "11111111-1111-1111-1111-111111111111")
        // Snapshot arrives → CodeView mounts in the live node.
        _ = try eval("""
        window.receiveEditSnapshot('11111111-1111-1111-1111-111111111111',
          { path: '/w/aihand/README.md', original: 'a\\n', modified: 'b\\n', lineOffset: 0, tooLarge: false }); true
        """)
        try wait("diff mounted under row") {
            ((try? self.eval("!!document.querySelector('.file-diff .monaco-diff-editor')")) as? Bool) == true
        }
        // Re-render keeps the same live node (re-parented, not rebuilt).
        _ = try eval("window.__node = window.__liveDiff.node; true")
        _ = try eval("""
        window.renderMessages([
          { id: 'u1', kind: 'user', text: 'go' },
          { id: '11111111-1111-1111-1111-111111111111', kind: 'tool', text: 'Edited aihand/README.md +6 -1', editSnapshot: true },
          { id: '22222222-2222-2222-2222-222222222222', kind: 'tool', text: 'Edited aihand/a.swift +1' }
        ], false, null); true
        """)
        XCTAssertEqual(try eval("document.querySelector('.file-diff').firstChild === window.__node") as? Bool, true)
        // Clicking the row again closes and disposes.
        _ = try eval("document.querySelector('.tool-detail.has-diff').click(); true")
        XCTAssertEqual(try eval("document.querySelectorAll('.file-diff').length") as? Int, 0)
        XCTAssertEqual(try eval("window.__liveDiff === null") as? Bool, true)
    }
}
