import AppKit
import Carbon.HIToolbox
import SwiftUI
import WebKit

/// WKWebView that owns `copy:` so context-menu Copy / Edit→Copy hit rich clipboard.
final class ChatTranscriptWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }

    /// Context-menu / Edit→Copy land here via the responder chain (WKWebView has no open `copy:`).
    @objc func copy(_ sender: Any?) {
        if ChatSelectionHotkeys.copyPendingToPasteboard() { return }
        evaluateJavaScript("window.selectionClipboardPayload && selectionClipboardPayload()") { result, _ in
            guard let dict = result as? [String: Any],
                  let text = dict["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            let html = dict["html"] as? String
            let plain = dict["plain"] as? String ?? text
            ChatSelectionHotkeys.pendingText = text
            ChatSelectionHotkeys.pendingPlain = plain
            ChatSelectionHotkeys.pendingHTML = html ?? ""
            ChatClipboard.write(plain: plain, html: html)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown,
           Int(event.keyCode) == kVK_ANSI_C,
           flags.contains(.command),
           !flags.contains(.shift),
           !flags.contains(.option),
           !flags.contains(.control),
           ChatSelectionHotkeys.hasPendingSelection {
            copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Live chat-selection state for ⌘L / ⌘⇧L / ⌘C (panel key monitor + menu).
enum ChatSelectionHotkeys {
    static let addToChatNotification = Notification.Name("AiHandChatSelectionAddToChat")
    static let addToNewSessionNotification = Notification.Name("AiHandChatSelectionAddToNewSession")

    static var pendingText: String = ""
    /// List-aware plain (`- ` / `1. `) for plain-text paste targets.
    static var pendingPlain: String = ""
    /// HTML fragment for the current transcript selection (rich ⌘C).
    static var pendingHTML: String = ""
    static var onAddToChat: ((String) -> Void)?
    static var onAddToNewSession: ((String) -> Void)?

    static var hasPendingSelection: Bool {
        !pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pendingPlain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func clearPending() {
        pendingText = ""
        pendingPlain = ""
        pendingHTML = ""
    }

    @discardableResult
    static func perform(addToNewSession: Bool) -> Bool {
        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        clearPending()
        if addToNewSession {
            onAddToNewSession?(text)
        } else {
            onAddToChat?(text)
        }
        return true
    }

    /// Copy the live transcript selection (plain + HTML/RTF). Keeps the selection.
    @discardableResult
    static func copyPendingToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let plain = (pendingPlain.isEmpty ? pendingText : pendingPlain)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return false }
        ChatClipboard.write(
            plain: pendingPlain.isEmpty ? pendingText : pendingPlain,
            html: pendingHTML,
            to: pasteboard
        )
        return true
    }
}

/// Cursor-style agent transcript rendered in a WKWebView (markdown, tool cards, code).
struct ChatTranscriptView: NSViewRepresentable {
    let messages: [AgentMessage]
    var sessionID: UUID
    /// Ephemeral footer while the agent is working ("Exploring…", "Planning next moves").
    var liveActivity: String? = nil
    var onAddSelectionToChat: ((String) -> Void)? = nil
    var onAddSelectionToNewSession: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        let uc = config.userContentController
        uc.add(context.coordinator, name: "openImage")
        uc.add(context.coordinator, name: "imageMenu")
        uc.add(context.coordinator, name: "selectionAction")
        uc.add(context.coordinator, name: "selectionChanged")
        uc.add(context.coordinator, name: "copyText")
        uc.add(context.coordinator, name: "loadEditSnapshot")
        let webView = ChatTranscriptWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
#if swift(>=5.9)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
#endif
        context.coordinator.webView = webView
        context.coordinator.pendingSessionID = sessionID
        context.coordinator.pendingLiveActivity = liveActivity
        context.coordinator.onAddSelectionToChat = onAddSelectionToChat
        context.coordinator.onAddSelectionToNewSession = onAddSelectionToNewSession
        webView.loadHTMLString(Self.shellHTML, baseURL: AssetSchemeHandler.baseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onAddSelectionToChat = onAddSelectionToChat
        context.coordinator.onAddSelectionToNewSession = onAddSelectionToNewSession
        context.coordinator.push(messages: messages, sessionID: sessionID, liveActivity: liveActivity)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let uc = webView.configuration.userContentController
        uc.removeScriptMessageHandler(forName: "openImage")
        uc.removeScriptMessageHandler(forName: "imageMenu")
        uc.removeScriptMessageHandler(forName: "selectionAction")
        uc.removeScriptMessageHandler(forName: "selectionChanged")
        uc.removeScriptMessageHandler(forName: "copyText")
        uc.removeScriptMessageHandler(forName: "loadEditSnapshot")
        if ChatSelectionHotkeys.hasPendingSelection {
            // Selection dies with the web view.
            ChatSelectionHotkeys.clearPending()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onAddSelectionToChat: ((String) -> Void)?
        var onAddSelectionToNewSession: ((String) -> Void)?
        private var ready = false
        private var pendingMessages: [AgentMessage] = []
        var pendingSessionID: UUID?
        var pendingLiveActivity: String?
        private var boundSessionID: UUID?
        private var lastPayload: String = ""
        private var lastLiveActivity: String = "\u{0}"
        private var imageDataURLs: [String: String] = [:]
        private var imagesSentToPage: Set<String> = []

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            imagesSentToPage.removeAll()
            lastPayload = ""
            lastLiveActivity = "\u{0}"
            push(
                messages: pendingMessages,
                sessionID: pendingSessionID ?? boundSessionID,
                liveActivity: pendingLiveActivity,
                forceScroll: true
            )
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // Keep the in-memory transcript shell; never navigate the web view away.
            // The asset scheme is the shell's base URL: allow the initial load, but not link clicks
            // (relative markdown links resolve against it).
            let isShellLoad = url.scheme?.lowercased() == AssetSchemeHandler.scheme
                && navigationAction.navigationType == .other
                && navigationAction.targetFrame?.isMainFrame != false
            if url.isFileURL || url.scheme?.lowercased() == "about" || isShellLoad {
                decisionHandler(.allow)
                return
            }
            if Self.openInDefaultBrowser(url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.cancel)
        }

        /// `target="_blank"` markdown links never hit decidePolicy unless we handle this.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                _ = Self.openInDefaultBrowser(url)
            }
            return nil
        }

        @discardableResult
        private static func openInDefaultBrowser(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else {
                return false
            }
            return NSWorkspace.shared.open(url)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }

            switch message.name {
            case "openImage", "imageMenu":
                guard let key = body["key"] as? String,
                      !key.isEmpty,
                      FileManager.default.fileExists(atPath: key) else { return }
                if message.name == "openImage" {
                    ChatImageActions.open(path: key)
                    return
                }
                guard let webView else { return }
                let clientX = CGFloat((body["x"] as? Double) ?? (body["x"] as? Int).map(Double.init) ?? 0)
                let clientY = CGFloat((body["y"] as? Double) ?? (body["y"] as? Int).map(Double.init) ?? 0)
                // WKWebView is flipped — JS client coords already match view coords.
                let y = webView.isFlipped ? clientY : (webView.bounds.height - clientY)
                let point = NSPoint(x: clientX, y: y)
                ChatImageActions.showMenu(path: key, at: point, in: webView)
            case "selectionChanged":
                let text = (body["text"] as? String) ?? ""
                let html = (body["html"] as? String) ?? ""
                let plain = (body["plain"] as? String) ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // ⌘-hold re-lays out the panel and collapses the DOM selection —
                    // keep the sticky copy buffer so ⌘C still works.
                    if NSEvent.modifierFlags
                        .intersection(.deviceIndependentFlagsMask)
                        .contains(.command) {
                        return
                    }
                    ChatSelectionHotkeys.clearPending()
                } else {
                    ChatSelectionHotkeys.pendingText = text
                    ChatSelectionHotkeys.pendingPlain = plain.isEmpty ? text : plain
                    ChatSelectionHotkeys.pendingHTML = html
                }
            case "selectionAction":
                guard let action = body["action"] as? String,
                      let text = body["text"] as? String else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                ChatSelectionHotkeys.clearPending()
                switch action {
                case "chat":
                    onAddSelectionToChat?(trimmed)
                case "new":
                    onAddSelectionToNewSession?(trimmed)
                default:
                    break
                }
            case "loadEditSnapshot":
                guard let id = body["id"] as? String,
                      let messageID = UUID(uuidString: id),
                      let sessionID = boundSessionID ?? pendingSessionID else { return }
                loadEditSnapshot(messageID: messageID, sessionID: sessionID)
            case "copyText":
                guard let text = body["text"] as? String else { return }
                let html = body["html"] as? String
                // `text` is already list-aware plain when sent from selection copy.
                ChatClipboard.write(plain: text, html: html)
                if let html, !html.isEmpty {
                    ChatSelectionHotkeys.pendingText = text
                    ChatSelectionHotkeys.pendingPlain = text
                    ChatSelectionHotkeys.pendingHTML = html
                }
            default:
                break
            }
        }

        /// Reads the sidecar off the main thread and hands it to `window.receiveEditSnapshot`.
        private func loadEditSnapshot(messageID: UUID, sessionID: UUID) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let snapshot = EditSnapshotStore.read(sessionID: sessionID, messageID: messageID)
                let json = snapshot
                    .flatMap { try? JSONEncoder().encode($0) }
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                DispatchQueue.main.async {
                    guard let self, let webView = self.webView,
                          self.boundSessionID == nil || self.boundSessionID == sessionID else { return }
                    webView.evaluateJavaScript(
                        "window.receiveEditSnapshot && window.receiveEditSnapshot('\(messageID.uuidString)', \(json));",
                        completionHandler: nil
                    )
                }
            }
        }

        func push(
            messages: [AgentMessage],
            sessionID: UUID? = nil,
            liveActivity: String? = nil,
            forceScroll: Bool = false
        ) {
            pendingMessages = messages
            pendingLiveActivity = liveActivity
            if let sessionID {
                pendingSessionID = sessionID
            }
            guard ready, let webView else { return }

            let switched = sessionID != nil && sessionID != boundSessionID
            if let sessionID, switched {
                boundSessionID = sessionID
                lastPayload = ""
                lastLiveActivity = "\u{0}"
            }
            let shouldForceScroll = forceScroll || switched

            // Keep heavy screenshot payloads out of the per-token JS update:
            // send a stable key and let the page cache data-URLs separately.
            var imageLoads: [[String: String]] = []
            let payload: [[String: Any]] = messages.map { msg in
                var dict: [String: Any] = [
                    "id": msg.id.uuidString,
                    "kind": kindName(msg.kind),
                    "text": msg.text
                ]
                if msg.steered {
                    dict["steered"] = true
                }
                if msg.editSnapshot {
                    dict["editSnapshot"] = true
                }
                let paths = msg.imagePaths
                if !paths.isEmpty {
                    // Prefer `media` array; keep legacy single-key fields for the first item.
                    var mediaItems: [[String: String]] = []
                    for path in paths {
                        let video = Self.isVideoPath(path)
                        var item: [String: String] = ["key": path]
                        if video { item["kind"] = "video" }
                        mediaItems.append(item)
                        if imageDataURLs[path] == nil {
                            if video {
                                if let poster = Self.videoPosterDataURL(path: path) {
                                    imageDataURLs[path] = poster
                                }
                            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                                let mime = path.lowercased().hasSuffix(".jpg") || path.lowercased().hasSuffix(".jpeg")
                                    ? "image/jpeg" : "image/png"
                                imageDataURLs[path] = "data:\(mime);base64,\(data.base64EncodedString())"
                            }
                        }
                        if let url = imageDataURLs[path], !imagesSentToPage.contains(path) {
                            imagesSentToPage.insert(path)
                            imageLoads.append(["key": path, "url": url])
                        }
                    }
                    dict["media"] = mediaItems
                    if let first = paths.first {
                        dict["imageKey"] = first
                        if Self.isVideoPath(first) {
                            dict["mediaKind"] = "video"
                        }
                    }
                }
                return dict
            }

            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let activityKey = liveActivity ?? ""
            if json == lastPayload && imageLoads.isEmpty && activityKey == lastLiveActivity { return }
            lastPayload = json
            lastLiveActivity = activityKey
            var script = ""
            if shouldForceScroll {
                script += "window.__expandedGroups = {}; window.__expandedDiffs = {};"
            }
            if !imageLoads.isEmpty,
               let imgData = try? JSONSerialization.data(withJSONObject: imageLoads),
               let imgJSON = String(data: imgData, encoding: .utf8) {
                script += "window.cacheImages(\(imgJSON));"
            }
            // Top-level String is not a valid JSONSerialization root (throws NSException
            // that `try?` cannot catch) — wrap as a one-element array then peel it.
            let activityJSON: String
            if let liveActivity,
               let aData = try? JSONSerialization.data(withJSONObject: [liveActivity]),
               let aStr = String(data: aData, encoding: .utf8),
               aStr.count >= 2 {
                activityJSON = String(aStr.dropFirst().dropLast())
            } else {
                activityJSON = "null"
            }
            script += "window.renderMessages(\(json), \(shouldForceScroll ? "true" : "false"), \(activityJSON));"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        private func kindName(_ kind: AgentMessageKind) -> String {
            switch kind {
            case .user: return "user"
            case .assistant: return "assistant"
            case .tool: return "tool"
            case .system: return "system"
            case .status: return "status"
            }
        }

        private static func isVideoPath(_ path: String) -> Bool {
            switch (path as NSString).pathExtension.lowercased() {
            case "mov", "mp4", "m4v", "webm": return true
            default: return false
            }
        }

        private static func videoPosterDataURL(path: String) -> String? {
            guard let image = RegionRecorder.posterImage(for: URL(fileURLWithPath: path)),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                return nil
            }
            return "data:image/png;base64,\(png.base64EncodedString())"
        }
    }

    /// Loads vendored marked (assets/marked.min.js → app Resources).
    private static func markedJavaScript() -> String {
        if let url = Bundle.main.url(forResource: "marked.min", withExtension: "js"),
           let s = try? String(contentsOf: url, encoding: .utf8), !s.isEmpty {
            return s
        }
        // `swift test` / SPM: resolve from this source file → repo assets/.
        let repoAssets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AiHand
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo
            .appendingPathComponent("assets/marked.min.js")
        if let s = try? String(contentsOf: repoAssets, encoding: .utf8), !s.isEmpty {
            return s
        }
        return "/* marked.min.js missing */"
    }

    /// Built once (marked + template); safe to read from any thread after first access.
    static let shellHTML: String = {
        shellHTMLTemplate.replacingOccurrences(of: "/*__MARKED__*/", with: markedJavaScript())
    }()

    private static let shellHTMLTemplate = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="codeview/codeview.css">
    <style>
      :root {
        color-scheme: light dark;
        --bg: transparent;
        --text: #f5f5f7;
        --muted: #c7c7cc;
        --user-bg: rgba(10, 132, 255, 0.42);
        --user-border: rgba(255,255,255,0.18);
        --assistant-bg: transparent;
        --tool-bg: rgba(255,255,255,0.10);
        --tool-border: rgba(255,255,255,0.18);
        --system-bg: rgba(255, 170, 60, 0.22);
        --code-bg: rgba(0,0,0,0.42);
        --pre-bg: rgba(0,0,0,0.36);
        --border: rgba(255,255,255,0.16);
        --link: #8ec7ff;
        --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      }
      @media (prefers-color-scheme: light) {
        :root {
          --text: #1d1d1f;
          --muted: #3a3a3c;
          --user-bg: rgba(0, 122, 255, 0.16);
          --user-border: rgba(0,0,0,0.08);
          --tool-bg: rgba(0,0,0,0.05);
          --tool-border: rgba(0,0,0,0.12);
          --system-bg: rgba(255, 149, 0, 0.18);
          --code-bg: rgba(0,0,0,0.07);
          --pre-bg: rgba(0,0,0,0.05);
          --border: rgba(0,0,0,0.12);
          --link: #0071e3;
        }
      }
      * { box-sizing: border-box; }
      html, body {
        margin: 0; padding: 0;
        background: var(--bg);
        color: var(--text);
        font: 14.5px/1.55 var(--sans);
        -webkit-user-select: text;
        user-select: text;
      }
      #root {
        padding: 14px 16px 24px;
        display: flex;
        flex-direction: column;
        gap: 14px;
      }
      .msg { max-width: 100%; min-width: 0; }
      .msg.user {
        align-self: flex-end;
        max-width: 88%;
        /* Flex items default min-width:auto — long URLs otherwise refuse to shrink. */
        min-width: 0;
        overflow-wrap: anywhere;
        word-break: break-word;
        background: var(--user-bg);
        border: 1px solid var(--user-border);
        border-radius: 14px;
        padding: 10px 12px;
        color: var(--text);
      }
      .msg.user .steer-row {
        display: flex;
        align-items: flex-start;
        gap: 7px;
      }
      .msg.user .steer-row > .steer-icon {
        width: 12px;
        height: 12px;
        flex: none;
        margin-top: 0.28em;
        opacity: 0.72;
        color: var(--text);
      }
      .msg.user .steer-row > .steer-body {
        flex: 1;
        min-width: 0;
      }
      .msg.assistant { align-self: stretch; padding: 2px 0; color: var(--text); min-width: 0; }
      .msg.tool-group,
      .msg.worked-group {
        align-self: stretch;
        max-width: 100%;
        font: 14.5px/1.55 var(--sans);
        color: var(--muted);
      }
      .msg.tool-group .tool-summary,
      .msg.worked-group .tool-summary {
        display: inline-flex;
        gap: 6px;
        align-items: center;
        max-width: 100%;
        padding: 1px 0;
        cursor: pointer;
        user-select: none;
        -webkit-user-select: none;
        border-radius: 4px;
      }
      .msg.tool-group .tool-summary:hover,
      .msg.worked-group .tool-summary:hover { color: var(--text); }
      /* Cursor-style disclosure: chevron on the trailing edge — hover or expanded only. */
      .msg.tool-group .chev,
      .msg.worked-group .chev {
        flex: none;
        display: inline-flex;
        width: 10px;
        height: 10px;
        opacity: 0;
        transition: transform 0.12s ease, opacity 0.12s ease;
      }
      .msg.tool-group .tool-summary:hover .chev,
      .msg.tool-group.expanded .chev,
      .msg.worked-group .tool-summary:hover .chev,
      .msg.worked-group.expanded .chev {
        opacity: 0.9;
      }
      .msg.tool-group .chev svg,
      .msg.worked-group .chev svg {
        width: 10px;
        height: 10px;
        display: block;
      }
      .msg.tool-group.expanded .chev,
      .msg.worked-group.expanded .chev { transform: rotate(90deg); }
      .msg.tool-group .tool-body,
      .msg.worked-group .tool-body {
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .msg.tool-group .tool-details,
      .msg.worked-group .tool-details {
        display: none;
        margin: 4px 0 2px 0;
        padding: 0;
        font-family: var(--mono);
        font-size: 12.5px;
        color: var(--muted);
      }
      .msg.tool-group.expanded .tool-details,
      .msg.worked-group.expanded .tool-details { display: block; }
      .msg.tool-group .tool-detail,
      .msg.worked-group .tool-detail {
        display: flex;
        gap: 6px;
        align-items: center;
        padding: 2px 0;
      }
      .msg.tool-group .tool-detail .glyph,
      .msg.worked-group .tool-detail .glyph {
        flex: none;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 12px;
        height: 12px;
        opacity: 0.72;
        color: var(--muted);
      }
      .msg.tool-group .tool-detail .glyph svg,
      .msg.worked-group .tool-detail .glyph svg {
        width: 12px;
        height: 12px;
        display: block;
      }
      .msg.tool-group .tool-detail .tool-body,
      .msg.worked-group .tool-detail .tool-body {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        word-break: break-word;
        text-overflow: clip;
        color: var(--muted);
      }
      .msg.worked-group,
      .msg.edits-group {
        margin: 2px 0 6px;
      }
      .msg.edits-group {
        align-self: stretch;
        max-width: 100%;
        font: 14.5px/1.55 var(--sans);
        color: var(--muted);
      }
      .msg.edits-group .tool-summary {
        display: inline-flex;
        gap: 6px;
        align-items: center;
        max-width: 100%;
        padding: 1px 0;
        cursor: pointer;
        user-select: none;
        -webkit-user-select: none;
        border-radius: 4px;
      }
      .msg.edits-group .tool-summary:hover { color: var(--text); }
      .msg.edits-group .chev {
        flex: none;
        display: inline-flex;
        width: 10px;
        height: 10px;
        opacity: 0;
        transition: transform 0.12s ease, opacity 0.12s ease;
      }
      .msg.edits-group .tool-summary:hover .chev,
      .msg.edits-group.expanded > .tool-summary .chev { opacity: 0.9; }
      .msg.edits-group .chev svg {
        width: 10px;
        height: 10px;
        display: block;
      }
      .msg.edits-group.expanded > .tool-summary .chev { transform: rotate(90deg); }
      .msg.edits-group .tool-body {
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .msg.edits-group .tool-details {
        display: none;
        margin: 4px 0 2px 0;
        padding: 0;
        font-family: var(--mono);
        font-size: 12.5px;
        color: var(--muted);
      }
      .msg.edits-group.expanded .tool-details { display: block; }
      .msg.edits-group .tool-detail {
        display: flex;
        gap: 6px;
        align-items: center;
        flex-wrap: wrap;
        padding: 2px 0;
      }
      .msg.edits-group .tool-detail.has-diff {
        cursor: pointer;
        border-radius: 4px;
      }
      .msg.edits-group .tool-detail.has-diff:hover .tool-body { color: var(--text); }
      .msg.edits-group .tool-detail.has-diff:hover .chev,
      .msg.edits-group .tool-detail.has-diff.open .chev { opacity: 0.9; }
      .msg.edits-group .tool-detail.has-diff.open .chev { transform: rotate(90deg); }
      .msg.edits-group .file-diff {
        margin: 4px 0 8px 18px;
        font-family: var(--sans);
      }
      .msg.edits-group .tool-detail .glyph {
        flex: none;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 12px;
        height: 12px;
        opacity: 0.72;
        color: var(--muted);
      }
      .msg.edits-group .tool-detail .glyph svg {
        width: 12px;
        height: 12px;
        display: block;
      }
      .msg.edits-group .tool-detail .tool-body {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        word-break: break-word;
        text-overflow: clip;
        color: var(--muted);
      }
      .diff-add { color: #73c78c; font-variant-numeric: tabular-nums; }
      .diff-del { color: #f27a7a; font-variant-numeric: tabular-nums; }
      @media (prefers-color-scheme: light) {
        .diff-add { color: #1b7f3a; }
        .diff-del { color: #c0392b; }
      }
      .msg.system {
        align-self: stretch;
        background: var(--system-bg);
        border-radius: 10px;
        padding: 8px 10px;
        font-size: 13px;
        color: var(--text);
      }
      .msg.status {
        align-self: flex-start;
        margin: 2px 0 6px;
        padding: 0;
        border: none;
        background: transparent;
        font: 14.5px/1.55 var(--sans);
        color: var(--muted);
      }
      .msg.live-activity {
        align-self: flex-start;
        display: inline-flex;
        align-items: center;
        gap: 8px;
        margin: 8px 0 2px;
        padding: 0;
        border: none;
        background: transparent;
        font: 14.5px/1.55 var(--sans);
        color: var(--muted);
      }
      .msg.live-activity .live-strong {
        color: var(--text);
        opacity: 0.72;
      }
      .msg.live-activity .live-spinner {
        flex: none;
        width: 12px;
        height: 12px;
        border: 1.5px solid rgba(255,255,255,0.22);
        border-top-color: var(--muted);
        border-radius: 50%;
        animation: live-spin 0.7s linear infinite;
      }
      @media (prefers-color-scheme: light) {
        .msg.live-activity .live-spinner {
          border-color: rgba(0,0,0,0.14);
          border-top-color: var(--muted);
        }
      }
      @keyframes live-spin {
        to { transform: rotate(360deg); }
      }
      .msg .media-row {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
        margin-bottom: 8px;
      }
      .msg img.shot {
        display: block;
        max-width: min(280px, 100%);
        max-height: 180px;
        border-radius: 8px;
        margin-bottom: 0;
        object-fit: contain;
        cursor: zoom-in;
      }
      .msg .video-shot {
        position: relative;
        display: inline-block;
        max-width: min(280px, 100%);
        margin-bottom: 0;
        cursor: pointer;
      }
      .msg .video-shot img.shot {
        margin-bottom: 0;
        cursor: pointer;
      }
      .msg .video-shot .play {
        position: absolute;
        left: 50%;
        top: 50%;
        transform: translate(-50%, -50%);
        width: 36px;
        height: 36px;
        border-radius: 18px;
        background: rgba(0,0,0,0.55);
        border: 1.5px solid rgba(255,255,255,0.85);
        box-sizing: border-box;
        pointer-events: none;
      }
      .msg .video-shot .play::after {
        content: '';
        position: absolute;
        left: 13px;
        top: 10px;
        border-style: solid;
        border-width: 8px 0 8px 12px;
        border-color: transparent transparent transparent #fff;
      }
      .md {
        overflow-wrap: anywhere;
        word-break: break-word;
      }
      .md > *:first-child { margin-top: 0; }
      .md > *:last-child { margin-bottom: 0; }
      .md p { margin: 0.55em 0; }
      .md h1, .md h2, .md h3, .md h4 {
        margin: 0.9em 0 0.35em;
        font-weight: 650;
        line-height: 1.3;
      }
      .md h1 { font-size: 1.25em; }
      .md h2 { font-size: 1.12em; }
      .md h3 { font-size: 1.05em; }
      .md ul, .md ol {
        margin: 0.45em 0;
        padding-left: 1.35em;
      }
      .md ol { list-style-type: decimal; list-style-position: outside; }
      .md ul { list-style-type: disc; list-style-position: outside; }
      .md ul ul { list-style-type: circle; }
      .md ul ul ul { list-style-type: square; }
      .md li { margin: 0.2em 0; }
      .md li + li { margin-top: 0.15em; }
      .md li > ul, .md li > ol { margin: 0.15em 0; }
      .md a {
        color: var(--link);
        cursor: pointer;
        text-decoration: none;
        /* Bare autolinks are one long token — break inside the bubble, not past it. */
        overflow-wrap: anywhere;
        word-break: break-word;
      }
      .md code {
        font-family: var(--mono);
        font-size: 0.9em;
        color: var(--text);
        background: var(--code-bg);
        padding: 0.12em 0.35em;
        border-radius: 4px;
      }
      .md .code-block {
        position: relative;
        margin: 0.7em 0;
      }
      .md .code-block pre {
        background: var(--pre-bg);
        border: 1px solid var(--border);
        border-radius: 10px;
        padding: 10px 40px 10px 12px;
        margin: 0;
        overflow-x: hidden;
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        word-break: break-word;
        color: var(--text);
      }
      .md .code-block pre code {
        background: none;
        padding: 0;
        font-size: 13px;
        line-height: 1.45;
        color: var(--text);
        white-space: inherit;
        overflow-wrap: inherit;
        word-break: inherit;
      }
      .md .code-copy {
        appearance: none;
        position: absolute;
        top: 8px;
        right: 8px;
        z-index: 1;
        width: 26px;
        height: 26px;
        padding: 0;
        margin: 0;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border: 1px solid var(--border);
        border-radius: 7px;
        background: var(--pre-bg);
        color: var(--muted);
        cursor: pointer;
        -webkit-user-select: none;
        user-select: none;
      }
      .md .code-block.single .code-copy {
        top: 50%;
        transform: translateY(-50%);
      }
      .md .code-copy:hover {
        color: var(--text);
        border-color: var(--text);
      }
      .md .code-copy svg {
        width: 13px;
        height: 13px;
        display: block;
      }
      .md .code-copy .icon-check { display: none; }
      .md .code-copy.copied .icon-copy { display: none; }
      .md .code-copy.copied .icon-check { display: block; }
      .md .code-copy.copied {
        color: #34c759;
        border-color: rgba(52, 199, 89, 0.45);
      }
      /* Custom tip — native `title` is slow and system-styled. */
      .md .code-copy[data-tip]::after {
        content: attr(data-tip);
        position: absolute;
        right: 0;
        bottom: calc(100% + 6px);
        padding: 4px 8px;
        border-radius: 6px;
        background: rgba(20, 20, 22, 0.96);
        color: #f2f2f7;
        font: 600 11px/1.25 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
        letter-spacing: -0.01em;
        white-space: nowrap;
        pointer-events: none;
        opacity: 0;
        transform: translateY(2px);
        transition: opacity 0.12s ease, transform 0.12s ease;
        box-shadow: 0 4px 14px rgba(0, 0, 0, 0.35);
        border: 1px solid rgba(255, 255, 255, 0.1);
        z-index: 2;
      }
      .md .code-copy[data-tip]:hover::after,
      .md .code-copy[data-tip]:focus-visible::after {
        opacity: 1;
        transform: translateY(0);
      }
      .md .code-copy.copied[data-tip]::after {
        content: "Copied";
        opacity: 1;
        transform: translateY(0);
      }
      .md .code-block.single .code-copy[data-tip]::after {
        /* Vertically centered button — keep the tip above the chip, not over code. */
        bottom: calc(50% + 18px);
      }
      .md blockquote {
        margin: 0.6em 0;
        padding: 0.2em 0 0.2em 0.85em;
        border-left: 3px solid var(--border);
        color: var(--muted);
      }
      .md hr {
        border: none;
        border-top: 1px solid var(--border);
        margin: 1em 0;
      }
      .md table {
        border-collapse: collapse;
        width: 100%;
        margin: 0.7em 0;
        font-size: 13.5px;
        overflow: hidden;
        border-radius: 8px;
        border: 1px solid var(--border);
      }
      .md th, .md td {
        border: 1px solid var(--border);
        padding: 6px 10px;
        text-align: left;
        vertical-align: top;
      }
      .md th {
        background: var(--card);
        font-weight: 600;
      }
      .md tr:nth-child(even) td {
        background: color-mix(in srgb, var(--card) 55%, transparent);
      }
      .md th[align="left"], .md td[align="left"] { text-align: left; }
      .md th[align="right"], .md td[align="right"] { text-align: right; }
      .md th[align="center"], .md td[align="center"] { text-align: center; }
      .md del {
        text-decoration: line-through;
        opacity: 0.85;
      }
      .md img {
        max-width: min(280px, 100%);
        max-height: 180px;
        border-radius: 8px;
        display: block;
        margin: 0.4em 0;
      }
      .md li input[type="checkbox"] {
        margin-right: 0.4em;
        vertical-align: middle;
      }
      .empty {
        color: var(--muted);
        text-align: center;
        padding: 40px 20px;
        font-size: 14px;
      }
      #sel-toolbar {
        display: none;
        position: fixed;
        z-index: 1000;
        align-items: center;
        gap: 0;
        padding: 3px;
        background: rgba(36, 36, 36, 0.96);
        border: 1px solid rgba(255,255,255,0.16);
        border-radius: 10px;
        box-shadow: 0 10px 28px rgba(0,0,0,0.42);
        -webkit-user-select: none;
        user-select: none;
        backdrop-filter: blur(12px);
        -webkit-backdrop-filter: blur(12px);
      }
      @media (prefers-color-scheme: light) {
        #sel-toolbar {
          background: rgba(255,255,255,0.96);
          border-color: rgba(0,0,0,0.12);
          box-shadow: 0 10px 28px rgba(0,0,0,0.14);
        }
      }
      #sel-toolbar button {
        appearance: none;
        border: none;
        background: transparent;
        color: var(--text);
        font: 500 12.5px/1.2 var(--sans);
        padding: 6px 10px;
        border-radius: 7px;
        cursor: pointer;
        white-space: nowrap;
        display: inline-flex;
        align-items: center;
        gap: 8px;
      }
      #sel-toolbar button:hover {
        background: rgba(255,255,255,0.10);
      }
      @media (prefers-color-scheme: light) {
        #sel-toolbar button:hover {
          background: rgba(0,0,0,0.06);
        }
      }
      #sel-toolbar .keys {
        display: inline-flex;
        align-items: center;
        gap: 3px;
      }
      #sel-toolbar kbd {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        min-width: 18px;
        height: 18px;
        padding: 0 4px;
        border-radius: 4px;
        background: rgba(255,255,255,0.10);
        border: 1px solid rgba(255,255,255,0.14);
        color: rgba(255,255,255,0.78);
        font: 600 11px/1 var(--sans);
        box-sizing: border-box;
      }
      @media (prefers-color-scheme: light) {
        #sel-toolbar kbd {
          background: rgba(0,0,0,0.06);
          border-color: rgba(0,0,0,0.10);
          color: rgba(0,0,0,0.72);
        }
      }
      #sel-toolbar .sep {
        width: 1px;
        align-self: stretch;
        margin: 4px 1px;
        background: rgba(255,255,255,0.14);
        flex: none;
      }
      @media (prefers-color-scheme: light) {
        #sel-toolbar .sep {
          background: rgba(0,0,0,0.10);
        }
      }
    </style>
    </head>
    <body>
    <div id="root"></div>
    <div id="sel-toolbar" role="toolbar" aria-label="Selection actions">
      <button type="button" data-action="chat">
        <span>Add to chat</span>
        <span class="keys" aria-hidden="true"><kbd>⌘</kbd><kbd>L</kbd></span>
      </button>
      <span class="sep" aria-hidden="true"></span>
      <button type="button" data-action="new">
        <span>Add to new session</span>
        <span class="keys" aria-hidden="true"><kbd>⇧</kbd><kbd>⌘</kbd><kbd>L</kbd></span>
      </button>
    </div>
    <script>
    /*__MARKED__*/
    </script>
    <script src="codeview/codeview.js"></script>
    <script>
    function esc(s) {
      return String(s)
        .replace(/&/g,'&amp;')
        .replace(/</g,'&lt;')
        .replace(/>/g,'&gt;')
        .replace(/"/g,'&quot;');
    }

    var CODE_COPY_BTN =
      '<button type="button" class="code-copy" data-tip="Copy to clipboard" aria-label="Copy to clipboard">'
      + '<svg class="icon-copy" viewBox="0 0 16 16" aria-hidden="true">'
      + '<rect x="5.5" y="5.5" width="8" height="8" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/>'
      + '<path fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" '
      + 'd="M3.5 10.5V3.8A1.3 1.3 0 0 1 4.8 2.5h6.7"/>'
      + '</svg>'
      + '<svg class="icon-check" viewBox="0 0 16 16" aria-hidden="true">'
      + '<path fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" '
      + 'stroke-linejoin="round" d="M3.5 8.5 6.5 11.5 12.5 4.5"/>'
      + '</svg>'
      + '</button>';

    // CommonMark + GFM via marked. Footnotes stay off; raw HTML is escaped (not rendered).
    var __markedParse = null;
    (function configureMarked() {
      if (typeof marked === 'undefined') return;
      var api = (marked && marked.parse) ? marked : (marked.marked || marked);
      if (!api || (!api.parse && typeof api !== 'function')) return;
      var Renderer = api.Renderer || marked.Renderer;
      var renderer = Renderer ? new Renderer() : null;
      if (renderer) {
        // Escape raw HTML tokens so tags show as text (XSS-safe; intentional).
        renderer.html = function(token) {
          var text = (token && token.text != null) ? String(token.text) : String(token || '');
          return esc(text);
        };
        renderer.code = function(token) {
          var text = (token && token.text != null) ? String(token.text) : String(token || '');
          var lang = (token && token.lang) ? String(token.lang) : '';
          var lines = text.split('\\n');
          var single = lines.length <= 1 || (lines.length === 2 && lines[1] === '');
          var cls = lang ? (' class="language-' + esc(lang) + '"') : '';
          return '<div class="code-block' + (single ? ' single' : '') + '">'
            + CODE_COPY_BTN
            + '<pre><code' + cls + ' data-enhanced="1">' + esc(text) + '</code></pre></div>\\n';
        };
      }
      if (api.use) {
        try {
          api.use({
            gfm: true,
            breaks: false,
            pedantic: false,
            renderer: renderer || undefined
          });
        } catch (e) {
          if (renderer && api.use) {
            try { api.use({ renderer: renderer }); } catch (e2) {}
          }
        }
      } else if (api.setOptions && renderer) {
        try { api.setOptions({ renderer: renderer, gfm: true, breaks: false }); } catch (e3) {}
      }
      __markedParse = function(md) {
        if (api.parse) return api.parse(md, { async: false });
        if (typeof api === 'function') return api(md);
        return esc(md);
      };
    })();

    function markdownToHTML(md) {
      if (!md) return '';
      if (!__markedParse) {
        // marked failed to load — show escaped plain text rather than a blank bubble.
        return '<p>' + esc(String(md)).replace(/\\n/g, '<br>') + '</p>';
      }
      var html = __markedParse(String(md));
      // Footnotes are not enabled; strip if a build ever emits them.
      html = String(html)
        .replace(/<section class="footnotes"[\\s\\S]*?<\\/section>/gi, '')
        .replace(/<sup class="footnote-ref">[\\s\\S]*?<\\/sup>/gi, '');
      return enhanceCodeBlocks(html);
    }

    function enhanceCodeBlocks(html) {
      return String(html).replace(/<pre><code([^>]*)>([\\s\\S]*?)<\\/code><\\/pre>/g, function(_, attrs, body) {
        if (attrs.indexOf('data-enhanced') !== -1) return '<pre><code' + attrs + '>' + body + '</code></pre>';
        // Skip blocks our renderer already wrapped.
        // (heuristic: if we just matched a bare pre/code, wrap it)
        var lines = body.split('\\n');
        var single = lines.length <= 1 || (lines.length === 2 && lines[1] === '');
        return '<div class="code-block' + (single ? ' single' : '') + '">'
          + CODE_COPY_BTN
          + '<pre><code' + attrs + '>' + body + '</code></pre></div>';
      });
    }
    // Monochrome outline SVGs (match SF Symbol chrome — no emoji).
    function outlineGlyph(kind) {
      const attrs = 'viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"';
      if (kind === 'edit') {
        return '<svg ' + attrs + '>'
          + '<path d="M11.2 2.2l2.6 2.6-8.1 8.1H3.1v-2.6l8.1-8.1z"/>'
          + '<path d="M9.6 3.8l2.6 2.6"/>'
          + '</svg>';
      }
      if (kind === 'read') {
        return '<svg ' + attrs + '>'
          + '<path d="M4 2.5h6.2L13 5.3V13.5H4V2.5z"/>'
          + '<path d="M10.2 2.5V5.3H13"/>'
          + '<path d="M6 8h4.5M6 10.2h4.5"/>'
          + '</svg>';
      }
      if (kind === 'run') {
        return '<svg ' + attrs + '>'
          + '<rect x="2.5" y="3" width="11" height="10" rx="1.4"/>'
          + '<path d="M5 7.2l2 1.8L5 10.8"/>'
          + '<path d="M8.2 10.8H11"/>'
          + '</svg>';
      }
      if (kind === 'search') {
        return '<svg ' + attrs + '>'
          + '<circle cx="7" cy="7" r="3.6"/>'
          + '<path d="M9.7 9.7L13 13"/>'
          + '</svg>';
      }
      if (kind === 'think') {
        return '<svg ' + attrs + '>'
          + '<path d="M4.2 3.2h7.6a2 2 0 0 1 2 2v3.4a2 2 0 0 1-2 2H8.2L5.5 13v-2.4H4.2a2 2 0 0 1-2-2V5.2a2 2 0 0 1 2-2z"/>'
          + '</svg>';
      }
      return '<svg ' + attrs + '><circle cx="8" cy="8" r="1.4" fill="currentColor" stroke="none"/></svg>';
    }

    function toolGlyph(text) {
      const t = text.toLowerCase();
      if (t.startsWith('reading') || t.startsWith('read ')) return outlineGlyph('read');
      if (t.startsWith('writing') || t.startsWith('wrote') || t.startsWith('edit') || t.startsWith('deleting')) {
        return outlineGlyph('edit');
      }
      if (t.startsWith('ran') || t.startsWith('running') || t.startsWith('shell') || t.startsWith('command')) {
        return outlineGlyph('run');
      }
      if (t.startsWith('search') || t.startsWith('grep') || t.startsWith('glob') || t.startsWith('listed')) {
        return outlineGlyph('search');
      }
      return outlineGlyph('other');
    }

    function toolCategory(text) {
      const t = (text || '').toLowerCase();
      if (t.startsWith('reading') || t.startsWith('read ')) return 'read';
      if (t.startsWith('editing') || t.startsWith('writing') || t.startsWith('wrote') || t.startsWith('deleting')) return 'edit';
      if (t.startsWith('ran') || t.startsWith('running')) return 'run';
      if (t.startsWith('search') || t.startsWith('grep') || t.startsWith('glob') || t.startsWith('listed')) return 'search';
      return 'other';
    }

    function summarizeTools(items) {
      if (items.length === 1) return items[0].text || 'Tool';
      const counts = { read: 0, edit: 0, run: 0, search: 0, other: 0 };
      items.forEach(function(m) { counts[toolCategory(m.text)]++; });
      const files = counts.read + counts.edit;
      const parts = [];
      if (files) parts.push(files === 1 ? '1 file' : files + ' files');
      if (counts.search) parts.push(counts.search === 1 ? '1 search' : counts.search + ' searches');
      if (counts.run) parts.push(counts.run === 1 ? '1 command' : counts.run + ' commands');
      if (counts.other) parts.push(counts.other === 1 ? '1 other' : counts.other + ' other');
      if (!parts.length) return items.length + ' tools';
      return 'Exploring ' + parts.join(', ');
    }

    function liveActivityHTML(text) {
      if (!text) return '';
      // Emphasize counts; colorize edit +/- like Cursor ("Editing 2 files +79").
      let html = esc(text).replace(/(\\d+\\s+[a-z]+)/gi, '<span class="live-strong">$1</span>');
      html = html.replace(/\\+(\\d+)/g, '<span class="diff-add">+$1</span>');
      html = html.replace(/(^|[\\s])-(\\d+)/g, '$1<span class="diff-del">-$2</span>');
      return '<div class="msg live-activity" role="status" aria-live="polite">'
        + '<span class="live-spinner" aria-hidden="true"></span>'
        + '<span class="live-label">' + html + '</span>'
        + '</div>';
    }

    function chevronHTML() {
      return '<span class="chev" aria-hidden="true">'
        + '<svg viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">'
        + '<path d="M3.2 1.8 L6.8 5 L3.2 8.2"/></svg></span>';
    }

    function toolDetailRows(items) {
      return items.map(function(m) {
        const text = m.text || 'Tool';
        return '<div class="tool-detail">'
          + '<span class="glyph">' + toolGlyph(text) + '</span>'
          + '<span class="tool-body">' + esc(text) + '</span>'
          + '</div>';
      }).join('');
    }

    function toolGroupHTML(items, groupId, expanded) {
      const summary = summarizeTools(items);
      const open = expanded ? ' expanded' : '';
      return '<div class="msg tool-group' + open + '" data-group-id="' + esc(groupId) + '" aria-expanded="' + (expanded ? 'true' : 'false') + '">'
        + '<div class="tool-summary" role="button">'
        + '<span class="tool-body" title="' + esc(summary) + '">' + esc(summary) + '</span>'
        + chevronHTML()
        + '</div>'
        + '<div class="tool-details">' + toolDetailRows(items) + '</div>'
        + '</div>';
    }

    // "Worked for Xs" nests Thought chips + non-edit tool rows (Cursor-style turn disclosure).
    function workedGroupHTML(status, nested, groupId, expanded) {
      const summary = status.text || 'Worked';
      if (!nested.length) {
        return '<div class="msg status" data-id="' + esc(status.id || '') + '">' + esc(summary) + '</div>';
      }
      const open = expanded ? ' expanded' : '';
      const details = nested.map(function(n) {
        if (n.type === 'thought') {
          const text = n.item.text || 'Thought';
          return '<div class="tool-detail">'
            + '<span class="glyph">' + outlineGlyph('think') + '</span>'
            + '<span class="tool-body">' + esc(text) + '</span>'
            + '</div>';
        }
        return toolDetailRows(n.items || []);
      }).join('');
      return '<div class="msg worked-group' + open + '" data-group-id="' + esc(groupId) + '" data-id="' + esc(status.id || '') + '" aria-expanded="' + (expanded ? 'true' : 'false') + '">'
        + '<div class="tool-summary" role="button">'
        + '<span class="tool-body" title="' + esc(summary) + '">' + esc(summary) + '</span>'
        + chevronHTML()
        + '</div>'
        + '<div class="tool-details">' + details + '</div>'
        + '</div>';
    }

    function isWorkedChip(text) {
      return typeof text === 'string' && text.indexOf('Worked for ') === 0;
    }
    function isThoughtChip(text) {
      return typeof text === 'string' && text.indexOf('Thought ') === 0;
    }
    function isFileEditTool(text) {
      if (typeof text !== 'string') return false;
      return text.indexOf('Editing ') === 0
        || text.indexOf('Edited ') === 0
        || text.indexOf('Writing ') === 0
        || text.indexOf('Wrote ') === 0;
    }

    function parseEditStat(text) {
      if (!isFileEditTool(text)) return null;
      const prefixes = ['Edited ', 'Editing ', 'Wrote ', 'Writing '];
      let rest = text;
      for (let i = 0; i < prefixes.length; i++) {
        if (rest.indexOf(prefixes[i]) === 0) {
          rest = rest.slice(prefixes[i].length);
          break;
        }
      }
      let added = 0, removed = 0;
      while (true) {
        let m = rest.match(/ \\+(\\d+)$/);
        if (m) { added = parseInt(m[1], 10); rest = rest.slice(0, -m[0].length); continue; }
        m = rest.match(/ -(\\d+)$/);
        if (m) { removed = parseInt(m[1], 10); rest = rest.slice(0, -m[0].length); continue; }
        break;
      }
      const path = rest.replace(/^\\s+|\\s+$/g, '');
      if (!path) return null;
      return { path: path, added: added, removed: removed };
    }

    function diffStatsHTML(added, removed) {
      let s = '';
      if (added > 0) s += ' <span class="diff-add">+' + added + '</span>';
      if (removed > 0) s += ' <span class="diff-del">-' + removed + '</span>';
      return s;
    }

    function editsGroupHTML(items, groupId, expanded) {
      const paths = {};
      let added = 0, removed = 0, editCount = 0;
      let inProgress = false;
      items.forEach(function(it) {
        if (it.type !== 'edit') return;
        const text = it.item.text || '';
        if (text.indexOf('Editing ') === 0 || text.indexOf('Writing ') === 0) inProgress = true;
        const stat = parseEditStat(text);
        if (!stat) return;
        editCount++;
        paths[stat.path] = true;
        added += stat.added;
        removed += stat.removed;
      });
      const fileCount = Object.keys(paths).length || editCount;
      const noun = fileCount === 1 ? 'file' : 'files';
      const verb = inProgress ? 'Editing' : 'Edited';
      const summaryPlain = verb + ' ' + fileCount + ' ' + noun
        + (added > 0 ? ' +' + added : '')
        + (removed > 0 ? ' -' + removed : '');
      const summaryHTML = verb + ' ' + fileCount + ' ' + noun + diffStatsHTML(added, removed);
      const open = expanded ? ' expanded' : '';
      const details = items.map(function(it) {
        if (it.type === 'thought') {
          return '<div class="tool-detail">'
            + '<span class="glyph">' + outlineGlyph('think') + '</span>'
            + '<span class="tool-body">' + esc(it.item.text || 'Thought') + '</span>'
            + '</div>';
        }
        const text = it.item.text || 'Edit';
        const stat = parseEditStat(text);
        if (stat) {
          const rowInProgress = text.indexOf('Editing ') === 0 || text.indexOf('Writing ') === 0;
          const rowVerb = rowInProgress ? 'Editing' : 'Edited';
          const msgId = it.item.id || '';
          const hasDiff = !!it.item.editSnapshot && !rowInProgress && !!msgId;
          const diffOpen = hasDiff && expanded && !!window.__expandedDiffs[msgId];
          const attrs = hasDiff
            ? ' class="tool-detail has-diff' + (diffOpen ? ' open' : '') + '" role="button"'
              + ' data-msg-id="' + esc(msgId) + '" data-added="' + stat.added + '" data-removed="' + stat.removed + '"'
            : ' class="tool-detail"';
          return '<div' + attrs + '>'
            + '<span class="glyph">' + outlineGlyph('edit') + '</span>'
            + '<span class="tool-body">' + rowVerb + ' ' + esc(stat.path) + diffStatsHTML(stat.added, stat.removed) + '</span>'
            + (hasDiff ? chevronHTML() : '')
            + '</div>'
            + (diffOpen ? fileDiffPlaceholderHTML(msgId, stat) : '');
        }
        return '<div class="tool-detail">'
          + '<span class="glyph">' + outlineGlyph('edit') + '</span>'
          + '<span class="tool-body">' + esc(text) + '</span>'
          + '</div>';
      }).join('');
      return '<div class="msg edits-group' + open + '" data-group-id="' + esc(groupId) + '" aria-expanded="' + (expanded ? 'true' : 'false') + '">'
        + '<div class="tool-summary" role="button">'
        + '<span class="tool-body" title="' + esc(summaryPlain) + '">' + summaryHTML + '</span>'
        + chevronHTML()
        + '</div>'
        + '<div class="tool-details">' + details + '</div>'
        + '</div>';
    }


    function fileDiffPlaceholderHTML(msgId, stat) {
      return '<div class="file-diff" data-msg-id="' + esc(msgId) + '"'
        + ' data-added="' + (stat.added || 0) + '" data-removed="' + (stat.removed || 0) + '"></div>';
    }

    // One live Monaco diff at a time; its DOM node survives re-renders by being re-parented.
    window.__expandedDiffs = window.__expandedDiffs || {};
    window.__liveDiff = window.__liveDiff || null;

    function disposeLiveDiff() {
      const live = window.__liveDiff;
      window.__liveDiff = null;
      if (live && live.handle) live.handle.dispose();
      if (live && live.node && live.node.parentNode) live.node.parentNode.removeChild(live.node);
    }

    function mountFileDiffs(root) {
      const ph = root.querySelector('.file-diff[data-msg-id]');
      const live = window.__liveDiff;
      if (!ph) { if (live) disposeLiveDiff(); return; }
      const id = ph.getAttribute('data-msg-id');
      if (live && live.id === id) { ph.appendChild(live.node); return; }
      if (live) disposeLiveDiff();
      const node = document.createElement('div');
      node.className = 'file-diff-host';
      ph.appendChild(node);
      window.__liveDiff = {
        id: id,
        node: node,
        handle: null,
        added: parseInt(ph.getAttribute('data-added') || '0', 10),
        removed: parseInt(ph.getAttribute('data-removed') || '0', 10)
      };
      if (window.webkit && window.webkit.messageHandlers.loadEditSnapshot) {
        window.webkit.messageHandlers.loadEditSnapshot.postMessage({ id: id });
      }
    }

    window.receiveEditSnapshot = function(id, snap) {
      const live = window.__liveDiff;
      if (!live || live.id !== id || live.handle) return;
      if (!snap || !window.CodeView) {
        live.node.innerHTML = '<div class="cv"><div class="cv-body cv-message">Diff unavailable</div></div>';
        return;
      }
      live.handle = window.CodeView.createDiff(live.node, {
        path: snap.path,
        original: snap.original,
        modified: snap.modified,
        lineOffset: snap.lineOffset || 0,
        tooLarge: !!snap.tooLarge,
        added: live.added,
        removed: live.removed
      });
    };

    function toggleFileDiff(row) {
      const id = row.getAttribute('data-msg-id');
      if (!id) return;
      const wasOpen = !!window.__expandedDiffs[id];
      window.__expandedDiffs = {};
      document.querySelectorAll('.msg.edits-group .file-diff').forEach(function(n) { n.remove(); });
      document.querySelectorAll('.msg.edits-group .tool-detail.has-diff.open').forEach(function(n) {
        n.classList.remove('open');
      });
      if (wasOpen) { disposeLiveDiff(); return; }
      window.__expandedDiffs[id] = true;
      row.classList.add('open');
      row.insertAdjacentHTML('afterend', fileDiffPlaceholderHTML(id, {
        added: parseInt(row.getAttribute('data-added') || '0', 10),
        removed: parseInt(row.getAttribute('data-removed') || '0', 10)
      }));
      mountFileDiffs(document.getElementById('root'));
    }

    window.__images = window.__images || {};
    window.__expandedGroups = window.__expandedGroups || {};
    window.cacheImages = function(items) {
      (items || []).forEach(function(item) {
        if (item && item.key && item.url) window.__images[item.key] = item.url;
      });
    };
    window.renderMessages = function(messages, forceScroll, liveActivity) {
      const root = document.getElementById('root');
      if ((!messages || !messages.length) && !liveActivity) {
        disposeLiveDiff();
        root.innerHTML = '<div class="empty">Send a message to start.</div>';
        if (forceScroll) window.scrollTo(0, 0);
        return;
      }

      // Nest Thought + non-edit tools under Worked; aggregate file edits (+ Thought) as "Edited N files".
      const blocks = [];
      for (let i = 0; i < (messages || []).length; i++) {
        const m = messages[i];
        const kind = m.kind || 'assistant';
        if (kind === 'status' && isWorkedChip(m.text || '')) {
          let editsAhead = false;
          for (let j = i + 1; j < messages.length; j++) {
            const peek = messages[j];
            const pk = peek.kind || '';
            if (pk === 'user' || pk === 'assistant' || pk === 'system') break;
            if (pk === 'status' && isWorkedChip(peek.text || '')) break;
            if (pk === 'tool' && isFileEditTool(peek.text || '')) { editsAhead = true; break; }
          }
          if (editsAhead) {
            // File-edit cluster owns Thought chips; keep Worked as a plain duration chip.
            blocks.push({ type: 'worked', status: m, nested: [] });
          } else {
            const nested = [];
            while (i + 1 < messages.length) {
              const next = messages[i + 1];
              const nk = next.kind || '';
              if (nk === 'status' && isThoughtChip(next.text || '')) {
                i++;
                nested.push({ type: 'thought', item: next });
                continue;
              }
              if (nk === 'tool' && !isFileEditTool(next.text || '')) {
                const tools = [next];
                i++;
                while (i + 1 < messages.length
                  && (messages[i + 1].kind || '') === 'tool'
                  && !isFileEditTool(messages[i + 1].text || '')) {
                  i++;
                  tools.push(messages[i]);
                }
                nested.push({ type: 'tools', items: tools });
                continue;
              }
              break;
            }
            blocks.push({ type: 'worked', status: m, nested: nested });
          }
        } else if ((kind === 'status' && isThoughtChip(m.text || ''))
          || (kind === 'tool' && isFileEditTool(m.text || ''))) {
          // Collect Thought + file-edit rows into one Cursor-style "Edited N files" disclosure.
          const cluster = [];
          let j = i;
          let sawEdit = kind === 'tool' && isFileEditTool(m.text || '');
          while (j < messages.length) {
            const cur = messages[j];
            const ck = cur.kind || '';
            if (ck === 'status' && isThoughtChip(cur.text || '')) {
              cluster.push({ type: 'thought', item: cur });
              j++;
              continue;
            }
            if (ck === 'tool' && isFileEditTool(cur.text || '')) {
              cluster.push({ type: 'edit', item: cur });
              sawEdit = true;
              j++;
              continue;
            }
            break;
          }
          if (sawEdit) {
            blocks.push({ type: 'edits', items: cluster });
            i = j - 1;
          } else {
            blocks.push({ type: 'msg', item: m });
          }
        } else if (kind === 'tool') {
          const tools = [m];
          while (i + 1 < messages.length
            && (messages[i + 1].kind || '') === 'tool'
            && !isFileEditTool(messages[i + 1].text || '')) {
            i++;
            tools.push(messages[i]);
          }
          blocks.push({ type: 'tools', items: tools });
        } else {
          blocks.push({ type: 'msg', item: m });
        }
      }

      const html = blocks.map(function(block, bi) {
        if (block.type === 'worked') {
          const groupId = 'w-' + bi + '-' + (block.status && block.status.id ? block.status.id : bi);
          return workedGroupHTML(block.status, block.nested, groupId, !!window.__expandedGroups[groupId]);
        }
        if (block.type === 'edits') {
          const first = block.items[0] && block.items[0].item;
          const groupId = 'e-' + bi + '-' + (first && first.id ? first.id : bi);
          // Collapsed by default — only open when previously expanded this session.
          return editsGroupHTML(block.items, groupId, !!window.__expandedGroups[groupId]);
        }
        if (block.type === 'tools') {
          const groupId = 'g-' + bi + '-' + (block.items[0] && block.items[0].id ? block.items[0].id : bi);
          return toolGroupHTML(block.items, groupId, !!window.__expandedGroups[groupId]);
        }
        const m = block.item;
        const kind = m.kind || 'assistant';
        let body = '';
        const mediaList = (m.media && m.media.length)
          ? m.media
          : (m.imageKey ? [{ key: m.imageKey, kind: m.mediaKind === 'video' ? 'video' : undefined }] : []);
        if (mediaList.length) {
          body += '<div class="media-row">';
          mediaList.forEach(function(item) {
            const key = item.key;
            const image = m.image || (key ? window.__images[key] : null);
            const keyAttr = key ? ' data-key="' + esc(key) + '"' : '';
            if (item.kind === 'video') {
              if (image) {
                body += '<div class="video-shot"' + keyAttr + ' title="Click to play">'
                  + '<img class="shot" src="' + image + '" alt="Screen recording">'
                  + '<span class="play"></span></div>';
              } else if (key) {
                body += '<div class="video-shot"' + keyAttr + ' title="Click to play">'
                  + '<div class="shot" style="width:160px;height:90px;background:rgba(0,0,0,0.35);border-radius:8px;"></div>'
                  + '<span class="play"></span></div>';
              }
            } else if (image) {
              body += '<img class="shot" src="' + image + '"' + keyAttr + ' alt="Screenshot" title="Click to open · Right-click to copy">';
            }
          });
          body += '</div>';
        }
        if (kind === 'assistant' || kind === 'user') {
          body += '<div class="md">' + markdownToHTML(m.text || '') + '</div>';
        } else {
          body += esc(m.text || '');
        }
        if (kind === 'user' && m.steered) {
          const icon = '<svg class="steer-icon" viewBox="0 0 16 16" aria-hidden="true">'
            + '<circle cx="8" cy="8" r="6.1" fill="none" stroke="currentColor" stroke-width="1.5"/>'
            + '<circle cx="8" cy="8" r="1.55" fill="currentColor"/>'
            + '<path fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" '
            + 'd="M8 2.7v2.9M4.05 10.35l2.45-1.45M11.95 10.35l-2.45-1.45"/>'
            + '</svg>';
          body = '<div class="steer-row" title="Steered">' + icon
            + '<div class="steer-body">' + body + '</div></div>';
        }
        return '<div class="msg ' + kind + '" data-id="' + esc(m.id) + '">' + body + '</div>';
      }).join('') + liveActivityHTML(liveActivity || '');
      const nearBottom = (window.innerHeight + window.scrollY) >= (document.body.scrollHeight - 80);
      root.innerHTML = html || liveActivityHTML(liveActivity || '');
      root.querySelectorAll('.msg.tool-group .tool-summary, .msg.worked-group .tool-summary, .msg.edits-group .tool-summary').forEach(function(summary) {
        summary.addEventListener('click', function(e) {
          e.preventDefault();
          const el = summary.parentElement;
          if (!el) return;
          const id = el.getAttribute('data-group-id');
          const next = !el.classList.contains('expanded');
          el.classList.toggle('expanded', next);
          el.setAttribute('aria-expanded', next ? 'true' : 'false');
          if (id) window.__expandedGroups[id] = next;
        });
      });
      root.querySelectorAll('.msg.edits-group .tool-detail.has-diff').forEach(function(row) {
        row.addEventListener('click', function(e) {
          e.preventDefault();
          e.stopPropagation();
          toggleFileDiff(row);
        });
      });
      mountFileDiffs(root);
      function bindMediaOpen(el) {
        el.addEventListener('click', function(e) {
          e.preventDefault();
          e.stopPropagation();
          var key = el.getAttribute('data-key');
          if (key && window.webkit && window.webkit.messageHandlers.openImage) {
            window.webkit.messageHandlers.openImage.postMessage({ key: key });
          }
        });
        el.addEventListener('contextmenu', function(e) {
          e.preventDefault();
          e.stopPropagation();
          var key = el.getAttribute('data-key');
          if (key && window.webkit && window.webkit.messageHandlers.imageMenu) {
            window.webkit.messageHandlers.imageMenu.postMessage({
              key: key,
              x: e.clientX,
              y: e.clientY
            });
          }
        });
      }
      root.querySelectorAll('img.shot[data-key]').forEach(bindMediaOpen);
      root.querySelectorAll('.video-shot[data-key]').forEach(bindMediaOpen);
      root.querySelectorAll('.code-block .code-copy').forEach(function(btn) {
        btn.addEventListener('click', function(e) {
          e.preventDefault();
          e.stopPropagation();
          var block = btn.closest('.code-block');
          var code = block && block.querySelector('pre code');
          var text = code ? String(code.textContent || '') : '';
          if (window.webkit && window.webkit.messageHandlers.copyText) {
            window.webkit.messageHandlers.copyText.postMessage({ text: text });
          }
          btn.classList.add('copied');
          if (btn._copyTimer) clearTimeout(btn._copyTimer);
          btn._copyTimer = setTimeout(function() {
            btn.classList.remove('copied');
            btn._copyTimer = null;
          }, 1200);
        });
      });
      if (forceScroll || nearBottom) {
        const goBottom = function() { window.scrollTo(0, document.body.scrollHeight); };
        goBottom();
        requestAnimationFrame(goBottom);
        root.querySelectorAll('img.shot').forEach(function(img) {
          if (!img.complete) img.addEventListener('load', goBottom, { once: true });
        });
      }
      hideSelectionToolbar();
    };

    var pendingSelectionText = '';
    var pendingSelectionHTML = '';
    var pendingSelectionPlain = '';
    var selToolbar = document.getElementById('sel-toolbar');

    function postSelectionChanged(text, html, plain) {
      if (window.webkit && window.webkit.messageHandlers.selectionChanged) {
        window.webkit.messageHandlers.selectionChanged.postMessage({
          text: text || '',
          html: html || '',
          plain: plain || ''
        });
      }
    }

    function hideSelectionToolbar(clearPending) {
      if (clearPending !== false) {
        pendingSelectionText = '';
        pendingSelectionHTML = '';
        pendingSelectionPlain = '';
        postSelectionChanged('', '', '');
      }
      if (selToolbar) selToolbar.style.display = 'none';
    }

    function currentSelectionText() {
      var sel = window.getSelection();
      if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return '';
      return String(sel.toString() || '').trim();
    }

    // Walk a DOM subtree into markdown-ish plain text (bullets / numbers / indent).
    function nodeToPlain(root) {
      var parts = [];
      function endsWithNewline() {
        return parts.length > 0 && /\\n$/.test(parts[parts.length - 1]);
      }
      function walk(n, listStack) {
        if (!n) return;
        if (n.nodeType === 3) {
          parts.push(String(n.nodeValue || '').replace(/\\u00a0/g, ' '));
          return;
        }
        if (n.nodeType !== 1) return;
        var tag = String(n.tagName || '').toLowerCase();
        if (tag === 'script' || tag === 'style' || tag === 'button' || tag === 'svg') return;
        if (tag === 'br') { parts.push('\\n'); return; }
        if (tag === 'ul' || tag === 'ol') {
          var next = listStack.concat([{ kind: tag, index: 0 }]);
          for (var i = 0; i < n.childNodes.length; i++) walk(n.childNodes[i], next);
          if (!listStack.length && !endsWithNewline()) parts.push('\\n');
          return;
        }
        if (tag === 'li') {
          var depth = listStack.length;
          var top = listStack[listStack.length - 1];
          var marker = '- ';
          if (top && top.kind === 'ol') {
            top.index += 1;
            marker = String(top.index) + '. ';
          }
          var indent = '';
          for (var d = 1; d < depth; d++) indent += '  ';
          if (parts.length && !endsWithNewline()) parts.push('\\n');
          parts.push(indent + marker);
          for (var j = 0; j < n.childNodes.length; j++) {
            var child = n.childNodes[j];
            if (child.nodeType === 1) {
              var ct = String(child.tagName || '').toLowerCase();
              if (ct === 'ul' || ct === 'ol') {
                if (!endsWithNewline()) parts.push('\\n');
                walk(child, listStack);
                continue;
              }
            }
            walk(child, listStack);
          }
          return;
        }
        if (tag === 'p' || tag === 'div' || tag === 'h1' || tag === 'h2' || tag === 'h3'
            || tag === 'h4' || tag === 'blockquote' || tag === 'pre' || tag === 'tr') {
          if (parts.length && !endsWithNewline()) parts.push('\\n');
          for (var k = 0; k < n.childNodes.length; k++) walk(n.childNodes[k], listStack);
          if (!endsWithNewline()) parts.push('\\n');
          return;
        }
        if (tag === 'td' || tag === 'th') {
          if (parts.length && !endsWithNewline() && parts[parts.length - 1] !== '') {
            var last = parts[parts.length - 1];
            if (last !== '\\n' && !/\\t$/.test(last)) parts.push('\\t');
          }
          for (var c = 0; c < n.childNodes.length; c++) walk(n.childNodes[c], listStack);
          return;
        }
        for (var m = 0; m < n.childNodes.length; m++) walk(n.childNodes[m], listStack);
      }
      walk(root, []);
      return parts.join('')
        .replace(/[ \\t]+\\n/g, '\\n')
        .replace(/\\n{3,}/g, '\\n\\n')
        .replace(/^\\n+|\\n+$/g, '');
    }

    // Wrap consecutive top-level <li> nodes in <ul> (cloneContents drops the parent list).
    function wrapOrphanListItems(root) {
      var nodes = Array.prototype.slice.call(root.childNodes);
      var run = [];
      function flush() {
        if (!run.length) return;
        var ul = document.createElement('ul');
        root.insertBefore(ul, run[0]);
        run.forEach(function(li) { ul.appendChild(li); });
        run = [];
      }
      nodes.forEach(function(n) {
        if (n.nodeType === 1 && String(n.tagName || '').toLowerCase() === 'li') {
          run.push(n);
        } else {
          flush();
        }
      });
      flush();
    }

    // Clone the live selection as { text, html, plain } for ⌘C / selectionChanged / copy.
    function selectionClipboardPayload() {
      var sel = window.getSelection();
      if (!sel || sel.rangeCount === 0 || sel.isCollapsed) {
        return { text: '', html: '', plain: '' };
      }
      var container = document.createElement('div');
      for (var i = 0; i < sel.rangeCount; i++) {
        container.appendChild(sel.getRangeAt(i).cloneContents());
      }
      container.querySelectorAll('.code-copy, #sel-toolbar, .steer-icon, .play').forEach(function(el) {
        el.remove();
      });
      wrapOrphanListItems(container);
      var html = container.innerHTML;
      var text = String(sel.toString() || '');
      var plain = nodeToPlain(container) || text;
      return { text: text, html: html, plain: plain };
    }
    window.selectionClipboardPayload = selectionClipboardPayload;

    function rememberSelectionPayload(payload) {
      pendingSelectionText = payload && payload.text ? payload.text : '';
      pendingSelectionHTML = payload && payload.html ? payload.html : '';
      pendingSelectionPlain = payload && payload.plain ? payload.plain : '';
      postSelectionChanged(pendingSelectionText, pendingSelectionHTML, pendingSelectionPlain);
    }

    function copySelectionToApp() {
      var payload = selectionClipboardPayload();
      var live = String(payload.text || '').trim();
      if (live) {
        rememberSelectionPayload(payload);
      } else if (!String(pendingSelectionText || '').trim()) {
        return false;
      }
      if (window.webkit && window.webkit.messageHandlers.copyText) {
        window.webkit.messageHandlers.copyText.postMessage({
          text: pendingSelectionPlain || pendingSelectionText,
          html: pendingSelectionHTML
        });
      }
      return true;
    }

    function runSelectionAction(action) {
      var text = pendingSelectionText || currentSelectionText();
      if (!action || !text) return false;
      if (window.webkit && window.webkit.messageHandlers.selectionAction) {
        window.webkit.messageHandlers.selectionAction.postMessage({
          action: action,
          text: text
        });
      }
      hideSelectionToolbar();
      var sel = window.getSelection();
      if (sel) sel.removeAllRanges();
      return true;
    }

    function updateSelectionToolbar() {
      if (!selToolbar) return;
      var payload = selectionClipboardPayload();
      var text = String(payload.text || '').trim();
      if (!text) {
        hideSelectionToolbar();
        return;
      }
      var sel = window.getSelection();
      if (!sel || sel.rangeCount === 0) {
        hideSelectionToolbar();
        return;
      }
      var range = sel.getRangeAt(0);
      var rect = range.getBoundingClientRect();
      if (!rect || (rect.width === 0 && rect.height === 0)) {
        hideSelectionToolbar();
        return;
      }
      rememberSelectionPayload(payload);
      selToolbar.style.display = 'flex';
      var tb = selToolbar.getBoundingClientRect();
      var left = rect.left + (rect.width / 2) - (tb.width / 2);
      var top = rect.top - tb.height - 8;
      left = Math.max(8, Math.min(left, window.innerWidth - tb.width - 8));
      if (top < 8) top = Math.min(window.innerHeight - tb.height - 8, rect.bottom + 8);
      selToolbar.style.left = left + 'px';
      selToolbar.style.top = top + 'px';
    }

    // Update sticky buffer when selection is non-empty. Do NOT clear on empty —
    // ⌘-hold layout churn collapses the DOM selection before ⌘C arrives.
    function syncPendingFromSelection() {
      var payload = selectionClipboardPayload();
      var text = String(payload.text || '').trim();
      if (!text) {
        if (selToolbar) selToolbar.style.display = 'none';
        return;
      }
      rememberSelectionPayload(payload);
    }

    document.addEventListener('mouseup', function(e) {
      if (selToolbar && selToolbar.contains(e.target)) return;
      requestAnimationFrame(function() {
        // User click with nothing selected → drop the sticky buffer.
        if (!currentSelectionText()) {
          hideSelectionToolbar(true);
          return;
        }
        updateSelectionToolbar();
      });
    });
    // Context-menu Copy + ⌘C when WebKit owns the event: put rich + list plain on the clipboard.
    document.addEventListener('copy', function(e) {
      var payload = selectionClipboardPayload();
      var live = String(payload.text || '').trim();
      if (live) rememberSelectionPayload(payload);
      var plain = live ? (payload.plain || live) : (pendingSelectionPlain || pendingSelectionText);
      var html = live ? (payload.html || '') : pendingSelectionHTML;
      if (!String(plain || '').trim()) return;
      var htmlDoc = '<!DOCTYPE html><html><body>' + (html || '') + '</body></html>';
      if (e.clipboardData) {
        try {
          e.clipboardData.setData('text/plain', plain);
          e.clipboardData.setData('text/html', htmlDoc);
          e.preventDefault();
        } catch (err) {}
      }
      if (window.webkit && window.webkit.messageHandlers.copyText) {
        window.webkit.messageHandlers.copyText.postMessage({
          text: plain,
          html: html || ''
        });
      }
    });
    document.addEventListener('keydown', function(e) {
      if (!(e.metaKey || e.ctrlKey) || e.altKey) return;
      // ⌘C / Ctrl+C — force rich copy (also covered by the `copy` event when WebKit delivers it).
      if ((e.key === 'c' || e.key === 'C') && !e.shiftKey) {
        if (copySelectionToApp()) {
          e.preventDefault();
          e.stopPropagation();
        }
        return;
      }
      if (e.key !== 'l' && e.key !== 'L') return;
      var text = pendingSelectionText || currentSelectionText();
      if (!text) return;
      e.preventDefault();
      e.stopPropagation();
      runSelectionAction(e.shiftKey ? 'new' : 'chat');
    }, true);
    document.addEventListener('keyup', function(e) {
      if (e.key === 'Escape') {
        hideSelectionToolbar(true);
        return;
      }
      // Shift+arrows / keyboard selection.
      if (e.shiftKey || e.key === 'ArrowLeft' || e.key === 'ArrowRight'
          || e.key === 'ArrowUp' || e.key === 'ArrowDown') {
        requestAnimationFrame(updateSelectionToolbar);
      }
    });
    document.addEventListener('selectionchange', function() {
      syncPendingFromSelection();
    });
    document.addEventListener('scroll', function() {
      if (selToolbar && selToolbar.style.display !== 'none') {
        requestAnimationFrame(updateSelectionToolbar);
      }
    }, true);
    if (selToolbar) {
      selToolbar.addEventListener('mousedown', function(e) {
        // Keep the selection while clicking toolbar buttons.
        e.preventDefault();
      });
      selToolbar.addEventListener('click', function(e) {
        var btn = e.target && e.target.closest ? e.target.closest('button[data-action]') : null;
        if (!btn) return;
        runSelectionAction(btn.getAttribute('data-action'));
      });
    }
    </script>
    </body>
    </html>
    """
}
