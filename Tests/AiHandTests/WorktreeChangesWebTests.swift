import AppKit
import WebKit
import XCTest
@testable import AiHand

/// Runs the real Changes page (sidebar, filter menu, stacked/single diffs) in a WKWebView,
/// answering its bridge with `WorktreeChangesWindow.respond` against a fixture repo.
final class WorktreeChangesWebTests: XCTestCase {
    private final class Nav: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }

    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var path = ""
        var widths: [Double] = []
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["op"] as? String == "sidebarWidth", let w = (body["width"] as? NSNumber)?.doubleValue {
                widths.append(w)
                return
            }
            WorktreeChangesWindow.respond(to: body, path: path, connection: nil) { [weak self] id, json in
                DispatchQueue.main.async {
                    self?.webView?.evaluateJavaScript("window.Changes.receive(\(id), \(json))", completionHandler: nil)
                }
            }
        }
    }

    private var window: NSWindow!
    private var webView: WKWebView!
    private let nav = Nav()
    private let bridge = Bridge()
    private var repo: URL!

    override func setUpWithError() throws {
        repo = try WorktreeDiffFixture.make()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        let shim = WKUserScript(source: """
        window.requestAnimationFrame = function(cb) { return setTimeout(function() { cb(performance.now()); }, 16); };
        window.cancelAnimationFrame = function(id) { clearTimeout(id); };
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(shim)
        config.userContentController.add(bridge, name: "changes")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
        webView.navigationDelegate = nav
        bridge.webView = webView
        bridge.path = repo.path
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.level = .floating
        window.orderFrontRegardless()
        webView.loadHTMLString(WorktreeChangesWindow.shellHTML, baseURL: AssetSchemeHandler.baseURL)
        try wait("shell load") { self.nav.done }
        _ = try eval("window.Changes.setContext({ branch: 'main', path: '\(repo.path)' }); true")
    }

    override func tearDown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "changes")
        window?.orderOut(nil)
        window = nil
        webView = nil
        if let repo { try? FileManager.default.removeItem(at: repo) }
    }

    private func wait(_ label: String, timeout: TimeInterval = 25, _ cond: () -> Bool) throws {
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

    private func count(_ selector: String) -> Int {
        ((try? eval("document.querySelectorAll('\(selector)').length")) as? Int) ?? 0
    }

    func testSidebarResizesByDraggingAndReportsWidth() throws {
        try wait("file rows") { self.count("#side .row[data-path]") == 3 }
        XCTAssertEqual(try eval("document.getElementById('side').offsetWidth") as? Int, 270)
        _ = try eval("""
        (function(){
          var bar = document.getElementById('resizer');
          function ev(t, x) { return new PointerEvent(t, { clientX: x, pointerId: 1, bubbles: true }); }
          bar.dispatchEvent(ev('pointerdown', 270));
          bar.dispatchEvent(ev('pointermove', 400));
          bar.dispatchEvent(ev('pointerup', 400));
          return true;
        })()
        """)
        XCTAssertEqual(try eval("document.getElementById('side').offsetWidth") as? Int, 400)
        XCTAssertEqual(bridge.widths.last, 400)
        // Clamped to the minimum, and double-click resets to the default.
        _ = try eval("window.Changes.setContext({ branch: 'main', path: '', sidebarWidth: 20 }); true")
        XCTAssertEqual(try eval("document.getElementById('side').offsetWidth") as? Int, 180)
        _ = try eval("document.getElementById('resizer').dispatchEvent(new MouseEvent('dblclick', { bubbles: true })); true")
        XCTAssertEqual(try eval("document.getElementById('side').offsetWidth") as? Int, 270)
        XCTAssertEqual(bridge.widths.last, 270)
    }

    func testKeyboardNavigationAndFilterShortcuts() throws {
        try wait("file rows") { self.count("#side .row[data-path]") == 3 }
        func key(_ k: String, meta: Bool = false) throws {
            _ = try eval("(document.activeElement || document).dispatchEvent(new KeyboardEvent('keydown', { key: '\(k)', metaKey: \(meta), bubbles: true, cancelable: true })); true")
        }
        func selected() -> String? {
            (try? eval("var r = document.querySelector('#side .row.sel'); r ? (r.getAttribute('data-path') || '*all') : null")) as? String
        }
        XCTAssertEqual(selected(), "*all")
        try key("ArrowDown")
        XCTAssertEqual(selected(), "a.txt")
        try wait("single diff") { self.count("#pane .slot") == 1 }
        try key("j")
        XCTAssertEqual(selected(), "b.txt")
        try key("End")
        XCTAssertEqual(selected(), "c.txt")
        try key("ArrowDown")
        XCTAssertEqual(selected(), "c.txt", "stops at the last file")
        try key("Home")
        XCTAssertEqual(selected(), "a.txt")
        try key("ArrowUp")
        XCTAssertEqual(selected(), "*all")
        try wait("stacked again") { self.count("#pane .slot") == 3 }
        try key("k")
        XCTAssertEqual(selected(), "*all")

        // ⌘F and "/" focus the filter; arrows still move the selection from inside it.
        try key("f", meta: true)
        XCTAssertEqual(try eval("document.activeElement.id") as? String, "fileFilter")
        try key("ArrowDown")
        XCTAssertEqual(selected(), "a.txt")
        try key("Escape")
        XCTAssertEqual(try eval("document.activeElement.id === 'fileFilter'") as? Bool, false)
        try key("/")
        XCTAssertEqual(try eval("document.activeElement.id") as? String, "fileFilter")
    }

    func testFileFilterBarNarrowsSidebarAndPane() throws {
        try wait("file rows") { self.count("#side .row[data-path]") == 3 }
        func type(_ text: String) throws {
            _ = try eval("var q = document.getElementById('fileFilter'); q.value = '\(text)'; q.dispatchEvent(new Event('input')); true")
        }
        try type("b.t")
        try wait("one row") { self.count("#side .row[data-path]") == 1 }
        XCTAssertEqual(try eval("document.querySelector('#side .row.all .badge').textContent === '1 of 3'") as? Bool, true)
        XCTAssertEqual(count("#pane .slot"), 1)

        try type("zzz")
        try wait("no matches") { self.count("#side .row[data-path]") == 0 }
        XCTAssertEqual(try eval("document.querySelector('#sideList').textContent.includes('No matching files')") as? Bool, true)
        XCTAssertEqual(try eval("document.querySelector('#pane .empty').textContent") as? String, "No matching files")

        // Esc in the field clears it.
        _ = try eval("document.getElementById('fileFilter').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); true")
        try wait("cleared") { self.count("#side .row[data-path]") == 3 }
        XCTAssertEqual(try eval("document.getElementById('fileFilter').value") as? String, "")
    }

    func testSidebarFilterMenuSingleFileAndReadOnlyDiffs() throws {
        // Default filter is Uncommitted: a, b, c in the sidebar (+ the "All files" row).
        try wait("file rows") { self.count("#side .row[data-path]") == 3 }
        XCTAssertEqual(try eval("document.querySelector('#filterBtn').textContent.includes('Uncommitted')") as? Bool, true)
        XCTAssertEqual(try eval("document.querySelector('#side .row.all .badge').textContent === '3'") as? Bool, true)
        XCTAssertEqual(count("#pane .slot"), 3)

        // Click one file → only that file's diff is shown.
        _ = try eval("document.querySelector('#side .row[data-path=\"a.txt\"]').click(); true")
        try wait("single slot") { self.count("#pane .slot") == 1 }
        try wait("diff mounted") { self.count("#pane .monaco-diff-editor") == 1 }
        XCTAssertEqual(try eval("document.querySelector('#pane .cv-path').textContent") as? String, "a.txt")
        // No commit / push affordances anywhere; the per-file header has no mode toggle (global one only).
        XCTAssertEqual(try eval("document.body.textContent.includes('Commit & Push')") as? Bool, false)
        XCTAssertEqual(count("#pane .cv-seg-btn"), 0)
        // Editors are read-only.
        XCTAssertEqual(
            try eval("""
            (function(){
              var eds = window.monaco.editor.getDiffEditors ? window.monaco.editor.getDiffEditors() : [];
              if (!eds.length) return true;
              var ro = window.monaco.editor.EditorOption.readOnly;
              return eds.every(function(d){ return d.getModifiedEditor().getOption(ro) && d.getOriginalEditor().getOption(ro); });
            })()
            """) as? Bool,
            true
        )

        // Mode toggle drives the diff editor.
        _ = try eval("document.querySelector('#modeSeg button[data-mode=\"side-by-side\"]').click(); true")
        XCTAssertEqual(try eval("window.Changes.state.mode") as? String, "side-by-side")
        try wait("side-by-side") {
            ((try? self.eval("document.querySelectorAll('#pane .editor.original .view-lines').length")) as? Int ?? 0) > 0
        }

        // "All files" returns to the stacked view.
        _ = try eval("document.querySelector('#side .row.all').click(); true")
        try wait("stacked slots") { self.count("#pane .slot") == 3 }

        // Filter menu → Staged shows only b.txt.
        _ = try eval("document.querySelector('#filterBtn').click(); true")
        try wait("menu items") { self.count("#menu .mi[data-filter]") == 4 }
        XCTAssertEqual(try eval("document.querySelector('#menu').textContent.includes('Commits')") as? Bool, true)
        _ = try eval("document.querySelector('#menu .mi[data-filter=\"staged\"]').click(); true")
        try wait("staged list") { self.count("#side .row[data-path]") == 1 }
        XCTAssertEqual(try eval("document.querySelector('#side .row[data-path]').getAttribute('data-path')") as? String, "b.txt")
        XCTAssertEqual(try eval("document.querySelector('#menu').hidden") as? Bool, true)

        // Commits submenu lists history; picking one shows that commit's files.
        _ = try eval("document.querySelector('#filterBtn').click(); true")
        try wait("menu reopened") { self.count("#menu .mi[data-filter]") == 4 }
        _ = try eval("document.querySelector('#menu .mi[data-filter=\"commits\"]').click(); true")
        try wait("commit rows") { self.count("#menu .commit") == 2 }
        // The list is a flyout beside the menu, not an inline expansion.
        XCTAssertEqual(try eval("document.querySelector('#menu .commits').classList.contains('fly')") as? Bool, true)
        // Dates are compact and fully inside the flyout (not clipped by the scrollbar).
        XCTAssertEqual(
            try eval("""
            (function(){
              var fly = document.querySelector('#menu .commits').getBoundingClientRect();
              var when = document.querySelector('#menu .commit .when');
              var r = when.getBoundingClientRect();
              return /^[0-9]+(s|m|h|d|w|mo|y)$/.test(when.textContent) && r.right <= fly.right - 8;
            })()
            """) as? Bool,
            true
        )
        // Hover leaves close it; hovering the row opens it again.
        _ = try eval("document.querySelector('#menu .sub').dispatchEvent(new MouseEvent('mouseleave')); true")
        try wait("flyout closes on leave") { self.count("#menu .commit") == 0 }
        _ = try eval("document.querySelector('#menu .sub').dispatchEvent(new MouseEvent('mouseenter')); true")
        try wait("flyout opens on hover") { self.count("#menu .commit") == 2 }
        _ = try eval("document.querySelector('#menu .commit').click(); true")
        try wait("commit files") {
            ((try? self.eval("document.querySelector('#side .row[data-path]') && document.querySelector('#side .row[data-path]').getAttribute('data-path')")) as? String) == "d.txt"
        }
        XCTAssertEqual(try eval("document.querySelector('#filterBtn').textContent.includes('second')") as? Bool, true)
    }
}
