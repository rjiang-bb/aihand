import AppKit
import WebKit

/// Read-only “Changes” window for a worktree: file sidebar + Monaco diffs (via CodeView),
/// filtered by Uncommitted / Staged / Unstaged / a past commit.
final class WorktreeChangesWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    /// Above the sessions panel (`floating + 2`) and next to chat image previews; Settings stays higher.
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)

    private static var open: [String: WorktreeChangesWindow] = [:]
    private static var onClosed: (() -> Void)?

    /// Optional callback after a Changes window closes (returns focus to sessions/chat).
    static func setClosedHandler(_ handler: (() -> Void)?) { onClosed = handler }

    /// Open (or re-focus) the window for a worktree.
    @discardableResult
    static func show(path: String, branch: String, connection: SSHConnection?) -> WorktreeChangesWindow {
        let key = SessionStore.normalizedWorkspace(path)
        if let existing = open[key] {
            existing.branch = branch
            existing.pushContext()
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }
        let controller = WorktreeChangesWindow(path: path, branch: branch, connection: connection)
        open[key] = controller
        controller.present()
        return controller
    }

    /// True when the key window is a Changes window.
    static var isKey: Bool {
        guard let key = NSApp.keyWindow else { return false }
        return open.values.contains { $0.window === key }
    }

    /// Close the key Changes window. Returns true when it handled the event.
    @discardableResult
    static func closeKeyIfNeeded() -> Bool {
        guard let key = NSApp.keyWindow, open.values.contains(where: { $0.window === key }) else { return false }
        key.performClose(nil)
        return true
    }

    static let sidebarWidthKey = "worktreeChangesSidebarWidth"

    /// User-resized file sidebar width (points); nil until they drag it.
    static var sidebarWidth: CGFloat? {
        get {
            let v = UserDefaults.standard.double(forKey: sidebarWidthKey)
            return v > 0 ? CGFloat(v) : nil
        }
        set {
            if let newValue, newValue > 0 {
                UserDefaults.standard.set(Double(newValue), forKey: sidebarWidthKey)
            } else {
                UserDefaults.standard.removeObject(forKey: sidebarWidthKey)
            }
        }
    }

    static var openWindows: [WorktreeChangesWindow] { Array(open.values) }

    // MARK: Instance

    let path: String
    private(set) var branch: String
    private let connection: SSHConnection?
    let window: NSWindow
    let webView: WKWebView
    private var loaded = false
    private var resignedOnce = false
    private let queue = DispatchQueue(label: "aihand.worktree-changes", qos: .userInitiated, attributes: .concurrent)

    private init(path: String, branch: String, connection: SSHConnection?) {
        self.path = path
        self.branch = branch
        self.connection = connection

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
#if swift(>=5.9)
        if #available(macOS 13.3, *) { webView.isInspectable = true }
#endif

        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 40, y: 40, width: 1200, height: 800)
        let size = NSSize(width: min(1100, visible.width * 0.8), height: min(760, visible.height * 0.8))
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        let uc = webView.configuration.userContentController
        uc.add(WeakHandler(self), name: "changes")
        uc.add(WeakHandler(self), name: "copyText")
        webView.navigationDelegate = self

        window.title = "Changes — \(branch)"
        window.contentView = webView
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        window.level = Self.windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()
    }

    private func present() {
        webView.loadHTMLString(Self.shellHTML, baseURL: AssetSchemeHandler.baseURL)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pushContext() {
        window.title = "Changes — \(branch)"
        guard loaded else { return }
        var context: [String: Any] = ["branch": branch, "path": path]
        if let width = Self.sidebarWidth { context["sidebarWidth"] = Double(width) }
        evaluate("window.Changes.setContext(\(Self.json(context)))")
    }

    private func evaluate(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: Bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "copyText" {
            if let body = message.body as? [String: Any], let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
        guard message.name == "changes", let body = message.body as? [String: Any] else { return }
        if body["op"] as? String == "sidebarWidth" {
            if let width = (body["width"] as? NSNumber)?.doubleValue { Self.sidebarWidth = CGFloat(width) }
            return
        }
        Self.respond(to: body, path: path, connection: connection, queue: queue) { [weak self] id, json in
            DispatchQueue.main.async { [weak self] in
                self?.evaluate("window.Changes.receive(\(id), \(json))")
            }
        }
    }

    /// Answers one `changes` bridge message off the main thread. `reply` gets (request id, JSON literal).
    static func respond(
        to body: [String: Any],
        path: String,
        connection: SSHConnection?,
        queue: DispatchQueue = .global(qos: .userInitiated),
        reply: @escaping (Int, String) -> Void
    ) {
        guard let op = body["op"] as? String, let id = body["id"] as? Int else { return }
        switch op {
        case "files":
            guard let filter = (body["filter"] as? [String: Any]).flatMap(WorktreeDiffFilter.init(json:)) else { return }
            queue.async {
                reply(id, encode(WorktreeDiff.files(filter: filter, in: path, connection: connection)))
            }
        case "counts":
            queue.async {
                let counts = WorktreeDiff.counts(in: path, connection: connection)
                reply(id, json(counts.mapValues { ["insertions": $0.insertions, "deletions": $0.deletions] }))
            }
        case "commits":
            let skip = body["skip"] as? Int ?? 0
            let limit = body["limit"] as? Int ?? 50
            queue.async {
                reply(id, encode(WorktreeDiff.commits(in: path, skip: skip, limit: limit, connection: connection)))
            }
        case "content":
            guard let filter = (body["filter"] as? [String: Any]).flatMap(WorktreeDiffFilter.init(json:)),
                  let fileJSON = body["file"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: fileJSON),
                  let file = try? JSONDecoder().decode(WorktreeChangedFile.self, from: data) else { return }
            queue.async {
                let content = WorktreeDiff.content(filter: filter, file: file, in: path, connection: connection)
                reply(id, json([
                    "original": content.original,
                    "modified": content.modified,
                    "binary": content.binary,
                    "tooLarge": content.tooLarge,
                ]))
            }
        default:
            break
        }
    }

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    // MARK: Delegates

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        pushContext()
    }

    func windowDidResignKey(_ notification: Notification) {
        resignedOnce = true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Pick up commits / edits made while the window was in the background.
        if loaded, resignedOnce { evaluate("window.Changes.refresh()") }
    }

    func windowWillClose(_ notification: Notification) {
        let uc = webView.configuration.userContentController
        uc.removeScriptMessageHandler(forName: "changes")
        uc.removeScriptMessageHandler(forName: "copyText")
        webView.navigationDelegate = nil
        let wasKey = NSApp.keyWindow === window
        Self.open = Self.open.filter { $0.value !== self }
        if wasKey || Self.open.isEmpty { Self.onClosed?() }
    }

    /// Avoids the content controller retaining the window controller.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            target?.userContentController(c, didReceive: m)
        }
    }

    // MARK: Shell

    private static let assetVersion = Int(Date().timeIntervalSince1970)

    static var shellHTML: String {
        let v = assetVersion
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="dark light">
        <link rel="stylesheet" href="codeview/codeview.css?v=\(v)">
        <link rel="stylesheet" href="codeview/changes.css?v=\(v)">
        </head>
        <body>
        <div id="app">
          <div id="bar">
            <div class="menu-wrap">
              <button id="filterBtn" class="btn" type="button" aria-haspopup="true"></button>
              <div id="menu" class="menu" hidden></div>
            </div>
            <span id="branch"></span>
            <span class="spacer"></span>
            <div id="modeSeg" role="group">
              <button type="button" data-mode="inline">Inline</button>
              <button type="button" data-mode="side-by-side">Side-by-side</button>
            </div>
          </div>
          <div id="main">
            <div id="side">
              <div id="filterWrap"><svg class="search-ic" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" aria-hidden="true"><circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14"/></svg><input id="fileFilter" type="text" placeholder="Filter files" spellcheck="false" autocomplete="off" autocapitalize="off"><span class="kbd" aria-hidden="true">⌘F</span></div>
              <div id="sideList"></div>
            </div>
            <div id="resizer" role="separator" aria-orientation="vertical" title="Drag to resize"></div>
            <div id="pane"></div>
          </div>
        </div>
        <script src="codeview/codeview.js?v=\(v)"></script>
        <script src="codeview/changes.js?v=\(v)"></script>
        </body>
        </html>
        """
    }
}
