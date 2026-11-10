import AppKit
import SwiftUI
import WebKit

/// Live chat-selection state for ⌘L / ⌘⇧L (panel key monitor + menu).
enum ChatSelectionHotkeys {
    static let addToChatNotification = Notification.Name("AiHandChatSelectionAddToChat")
    static let addToNewSessionNotification = Notification.Name("AiHandChatSelectionAddToNewSession")

    static var pendingText: String = ""
    static var onAddToChat: ((String) -> Void)?
    static var onAddToNewSession: ((String) -> Void)?

    @discardableResult
    static func perform(addToNewSession: Bool) -> Bool {
        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        pendingText = ""
        if addToNewSession {
            onAddToNewSession?(text)
        } else {
            onAddToChat?(text)
        }
        return true
    }
}

/// Cursor-style agent transcript rendered in a WKWebView (markdown, tool cards, code).
struct ChatTranscriptView: NSViewRepresentable {
    let messages: [AgentMessage]
    var sessionID: UUID
    var onAddSelectionToChat: ((String) -> Void)? = nil
    var onAddSelectionToNewSession: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let uc = config.userContentController
        uc.add(context.coordinator, name: "openImage")
        uc.add(context.coordinator, name: "imageMenu")
        uc.add(context.coordinator, name: "selectionAction")
        uc.add(context.coordinator, name: "selectionChanged")
        uc.add(context.coordinator, name: "copyText")
        let webView = WKWebView(frame: .zero, configuration: config)
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
        context.coordinator.onAddSelectionToChat = onAddSelectionToChat
        context.coordinator.onAddSelectionToNewSession = onAddSelectionToNewSession
        webView.loadHTMLString(Self.shellHTML, baseURL: URL(fileURLWithPath: "/"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onAddSelectionToChat = onAddSelectionToChat
        context.coordinator.onAddSelectionToNewSession = onAddSelectionToNewSession
        context.coordinator.push(messages: messages, sessionID: sessionID)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let uc = webView.configuration.userContentController
        uc.removeScriptMessageHandler(forName: "openImage")
        uc.removeScriptMessageHandler(forName: "imageMenu")
        uc.removeScriptMessageHandler(forName: "selectionAction")
        uc.removeScriptMessageHandler(forName: "selectionChanged")
        uc.removeScriptMessageHandler(forName: "copyText")
        if ChatSelectionHotkeys.pendingText.isEmpty == false {
            // Selection dies with the web view.
            ChatSelectionHotkeys.pendingText = ""
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onAddSelectionToChat: ((String) -> Void)?
        var onAddSelectionToNewSession: ((String) -> Void)?
        private var ready = false
        private var pendingMessages: [AgentMessage] = []
        var pendingSessionID: UUID?
        private var boundSessionID: UUID?
        private var lastPayload: String = ""
        private var imageDataURLs: [String: String] = [:]
        private var imagesSentToPage: Set<String> = []

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            imagesSentToPage.removeAll()
            lastPayload = ""
            push(messages: pendingMessages, sessionID: pendingSessionID ?? boundSessionID, forceScroll: true)
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
            if url.isFileURL || url.scheme?.lowercased() == "about" {
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
                let text = (body["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                ChatSelectionHotkeys.pendingText = text
            case "selectionAction":
                guard let action = body["action"] as? String,
                      let text = body["text"] as? String else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                ChatSelectionHotkeys.pendingText = ""
                switch action {
                case "chat":
                    onAddSelectionToChat?(trimmed)
                case "new":
                    onAddSelectionToNewSession?(trimmed)
                default:
                    break
                }
            case "copyText":
                guard let text = body["text"] as? String else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            default:
                break
            }
        }

        func push(messages: [AgentMessage], sessionID: UUID? = nil, forceScroll: Bool = false) {
            pendingMessages = messages
            if let sessionID {
                pendingSessionID = sessionID
            }
            guard ready, let webView else { return }

            let switched = sessionID != nil && sessionID != boundSessionID
            if let sessionID, switched {
                boundSessionID = sessionID
                lastPayload = ""
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
            if json == lastPayload && imageLoads.isEmpty { return }
            lastPayload = json
            var script = ""
            if shouldForceScroll {
                script += "window.__expandedGroups = {};"
            }
            if !imageLoads.isEmpty,
               let imgData = try? JSONSerialization.data(withJSONObject: imageLoads),
               let imgJSON = String(data: imgData, encoding: .utf8) {
                script += "window.cacheImages(\(imgJSON));"
            }
            script += "window.renderMessages(\(json), \(shouldForceScroll ? "true" : "false"));"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        private func kindName(_ kind: AgentMessageKind) -> String {
            switch kind {
            case .user: return "user"
            case .assistant: return "assistant"
            case .tool: return "tool"
            case .system: return "system"
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

    private static let shellHTML = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
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
      .msg.user .steer-badge {
        display: inline-flex;
        align-items: center;
        gap: 5px;
        margin: 6px 0 0;
        font: 600 11px/1.2 var(--sans);
        letter-spacing: 0.01em;
        color: var(--text);
        opacity: 0.62;
      }
      .msg.user .steer-badge svg {
        width: 11px;
        height: 11px;
        flex: none;
        opacity: 0.9;
      }
      .msg.assistant { align-self: stretch; padding: 2px 0; color: var(--text); min-width: 0; }
      .msg.tool-group {
        align-self: stretch;
        max-width: 100%;
        font: 13.5px/1.45 var(--sans);
        color: var(--muted);
      }
      .msg.tool-group .tool-summary {
        display: inline-flex;
        gap: 5px;
        align-items: center;
        max-width: 100%;
        padding: 1px 0;
        cursor: pointer;
        user-select: none;
        -webkit-user-select: none;
        border-radius: 4px;
      }
      .msg.tool-group .tool-summary:hover { color: var(--text); }
      .msg.tool-group .chev {
        flex: none;
        width: 9px;
        font-size: 8px;
        line-height: 1;
        opacity: 0.7;
        transition: transform 0.12s ease;
      }
      .msg.tool-group.expanded .chev { transform: rotate(90deg); }
      .msg.tool-group .tool-body {
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .msg.tool-group .tool-details {
        display: none;
        margin: 4px 0 2px 14px;
        padding: 0;
        font-family: var(--mono);
        font-size: 12.5px;
        color: var(--muted);
      }
      .msg.tool-group.expanded .tool-details { display: block; }
      .msg.tool-group .tool-detail {
        display: flex;
        gap: 6px;
        align-items: flex-start;
        padding: 2px 0;
      }
      .msg.tool-group .tool-detail .glyph {
        flex: none;
        opacity: 0.75;
        font-size: 12px;
        line-height: 1.45;
      }
      .msg.tool-group .tool-detail .tool-body {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        word-break: break-word;
        text-overflow: clip;
        color: var(--muted);
      }
      .msg.system {
        align-self: stretch;
        background: var(--system-bg);
        border-radius: 10px;
        padding: 8px 10px;
        font-size: 13px;
        color: var(--text);
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
        text-decoration: underline;
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
      }
      .md th, .md td {
        border: 1px solid var(--border);
        padding: 6px 8px;
        text-align: left;
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
      <button type="button" data-action="chat" title="Add to chat (⌘L)">
        <span>Add to chat</span>
        <span class="keys" aria-hidden="true"><kbd>⌘</kbd><kbd>L</kbd></span>
      </button>
      <span class="sep" aria-hidden="true"></span>
      <button type="button" data-action="new" title="Add to new session (⇧⌘L)">
        <span>Add to new session</span>
        <span class="keys" aria-hidden="true"><kbd>⇧</kbd><kbd>⌘</kbd><kbd>L</kbd></span>
      </button>
    </div>
    <script>
    function esc(s) {
      return String(s)
        .replace(/&/g,'&amp;')
        .replace(/</g,'&lt;')
        .replace(/>/g,'&gt;')
        .replace(/"/g,'&quot;');
    }

    function inlineMarkdown(src) {
      let s = esc(src);
      s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
      s = s.replace(/\\*\\*([^*]+)\\*\\*/g, '<strong>$1</strong>');
      s = s.replace(/(^|[^*])\\*([^*]+)\\*(?!\\*)/g, '$1<em>$2</em>');
      s = s.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
      // Autolink bare http(s) URLs that aren't already inside an href attribute.
      s = s.replace(/(^|[^"'>=])(https?:\\/\\/[^\\s<]+[^\\s<.,;:!?)\\]])/g, '$1<a href="$2" target="_blank" rel="noreferrer">$2</a>');
      return s;
    }

    function markdownToHTML(md) {
      if (!md) return '';
      const lines = String(md).replace(/\\r\\n?/g, '\\n').split('\\n');
      const out = [];
      let i = 0;
      let inPara = false;
      // Stack of open lists: { kind: 'ul'|'ol', level }. Nesting follows source indent
      // (composer uses 4 spaces / level); a flat renderer used to squash every nest.
      const listStack = [];
      let openLi = false;

      function listIndent(spaces) {
        return Math.min(3, Math.floor(spaces / 4));
      }
      function closeListsTo(level) {
        while (listStack.length > level) {
          if (openLi) { out.push('</li>'); openLi = false; }
          const top = listStack.pop();
          out.push('</' + top.kind + '>');
          // Parent <li> is still open after a nested list closes.
          openLi = listStack.length > 0;
        }
      }
      function closeLists() { closeListsTo(0); }
      function pushListItem(kind, level, body, start) {
        closePara();
        // Pop deeper nests and same-level lists of a different kind.
        while (listStack.length && (
          listStack[listStack.length - 1].level > level
          || (listStack[listStack.length - 1].level === level
              && listStack[listStack.length - 1].kind !== kind)
        )) {
          if (openLi) { out.push('</li>'); openLi = false; }
          const top = listStack.pop();
          out.push('</' + top.kind + '>');
          openLi = listStack.length > 0;
        }
        // Open any missing nest levels (at most one step past the parent).
        while (!listStack.length || listStack[listStack.length - 1].level < level) {
          const nextLevel = listStack.length ? listStack[listStack.length - 1].level + 1 : 0;
          // Nested list lives inside the parent's open <li>.
          if (kind === 'ol' && start > 1 && nextLevel === level) {
            out.push('<ol start="' + start + '">');
          } else {
            out.push('<' + kind + '>');
          }
          listStack.push({ kind: kind, level: nextLevel });
          openLi = false;
        }
        if (openLi) out.push('</li>');
        out.push('<li>' + inlineMarkdown(body));
        openLi = true;
      }
      function closePara() {
        if (inPara) { out.push('</p>'); inPara = false; }
      }

      while (i < lines.length) {
        const line = lines[i];

        // fenced code
        const fence = line.match(/^```(\\w*)\\s*$/);
        if (fence) {
          closePara(); closeLists();
          const lang = fence[1] || '';
          const buf = [];
          i++;
          while (i < lines.length && !/^```\\s*$/.test(lines[i])) {
            buf.push(lines[i]);
            i++;
          }
          const single = buf.length <= 1;
          out.push(
            '<div class="code-block' + (single ? ' single' : '') + '">'
            + '<button type="button" class="code-copy" data-tip="Copy to clipboard" aria-label="Copy to clipboard">'
            + '<svg class="icon-copy" viewBox="0 0 16 16" aria-hidden="true">'
            + '<rect x="5.5" y="5.5" width="8" height="8" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/>'
            + '<path fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" '
            + 'd="M3.5 10.5V3.8A1.3 1.3 0 0 1 4.8 2.5h6.7"/>'
            + '</svg>'
            + '<svg class="icon-check" viewBox="0 0 16 16" aria-hidden="true">'
            + '<path fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" '
            + 'stroke-linejoin="round" d="M3.5 8.5 6.5 11.5 12.5 4.5"/>'
            + '</svg>'
            + '</button>'
            + '<pre><code class="lang-' + esc(lang) + '">' + esc(buf.join('\\n')) + '</code></pre>'
            + '</div>'
          );
          i++;
          continue;
        }

        if (/^\\s*---\\s*$/.test(line)) {
          closePara(); closeLists();
          out.push('<hr>');
          i++; continue;
        }

        const heading = line.match(/^(#{1,4})\\s+(.+)$/);
        if (heading) {
          closePara(); closeLists();
          const level = heading[1].length;
          out.push('<h' + level + '>' + inlineMarkdown(heading[2]) + '</h' + level + '>');
          i++; continue;
        }

        const bq = line.match(/^>\\s?(.*)$/);
        if (bq) {
          closePara(); closeLists();
          const buf = [bq[1]];
          i++;
          while (i < lines.length) {
            const m = lines[i].match(/^>\\s?(.*)$/);
            if (!m) break;
            buf.push(m[1]);
            i++;
          }
          out.push('<blockquote><p>' + inlineMarkdown(buf.join(' ')) + '</p></blockquote>');
          continue;
        }

        // Bullets: -, *, or composer nest glyphs • ○ ▪. Leading spaces set the nest level.
        const ul = line.match(/^([ \\t]*)([-*•○◦▪■])\\s+(.+)$/);
        if (ul) {
          const spaces = ul[1].replace(/\\t/g, '    ').length;
          pushListItem('ul', listIndent(spaces), ul[3], 1);
          i++; continue;
        }

        // Ordered: "1. item" — markdown allows every line to say 1.; the <ol> increments.
        const ol = line.match(/^([ \\t]*)(\\d+)\\.\\s+(.+)$/);
        if (ol) {
          const spaces = ol[1].replace(/\\t/g, '    ').length;
          pushListItem('ol', listIndent(spaces), ol[3], parseInt(ol[2], 10));
          i++; continue;
        }

        if (/^\\s*$/.test(line)) {
          closePara();
          // Blank lines inside a list make it "loose" but must NOT restart numbering
          // (lazy "1. / 1. / 1." would otherwise render as three separate 1s).
          if (!listStack.length) {
            closeLists();
          }
          i++; continue;
        }

        closeLists();
        if (!inPara) { out.push('<p>'); inPara = true; }
        else { out.push('<br>'); }
        out.push(inlineMarkdown(line));
        i++;
      }
      closePara();
      closeLists();
      return out.join('');
    }

    function toolGlyph(text) {
      const t = text.toLowerCase();
      if (t.startsWith('reading') || t.startsWith('read ')) return '📄';
      if (t.startsWith('writing') || t.startsWith('wrote') || t.startsWith('edit') || t.startsWith('deleting')) return '✏️';
      if (t.startsWith('ran') || t.startsWith('running') || t.startsWith('shell') || t.startsWith('command')) return '⌘';
      if (t.startsWith('search') || t.startsWith('grep') || t.startsWith('glob') || t.startsWith('listed')) return '⌕';
      return '•';
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
      const parts = [];
      if (counts.read) parts.push(counts.read === 1 ? 'Read 1 file' : 'Read ' + counts.read + ' files');
      if (counts.edit) parts.push(counts.edit === 1 ? 'Edited 1 file' : 'Edited ' + counts.edit + ' files');
      if (counts.run) parts.push(counts.run === 1 ? 'Ran 1 command' : 'Ran ' + counts.run + ' commands');
      if (counts.search) parts.push(counts.search === 1 ? 'Searched once' : 'Searched ' + counts.search + ' times');
      if (counts.other) parts.push(counts.other === 1 ? '1 other tool' : counts.other + ' other tools');
      return parts.join(', ') || (items.length + ' tools');
    }

    function toolGroupHTML(items, groupId, expanded) {
      const summary = summarizeTools(items);
      const open = expanded ? ' expanded' : '';
      const details = items.map(function(m) {
        const text = m.text || 'Tool';
        return '<div class="tool-detail">'
          + '<span class="glyph">' + toolGlyph(text) + '</span>'
          + '<span class="tool-body">' + esc(text) + '</span>'
          + '</div>';
      }).join('');
      return '<div class="msg tool-group' + open + '" data-group-id="' + esc(groupId) + '" aria-expanded="' + (expanded ? 'true' : 'false') + '">'
        + '<div class="tool-summary" role="button">'
        + '<span class="chev">▶</span>'
        + '<span class="tool-body" title="' + esc(summary) + '">' + esc(summary) + '</span>'
        + '</div>'
        + '<div class="tool-details">' + details + '</div>'
        + '</div>';
    }

    window.__images = window.__images || {};
    window.__expandedGroups = window.__expandedGroups || {};
    window.cacheImages = function(items) {
      (items || []).forEach(function(item) {
        if (item && item.key && item.url) window.__images[item.key] = item.url;
      });
    };
    window.renderMessages = function(messages, forceScroll) {
      const root = document.getElementById('root');
      if (!messages || !messages.length) {
        root.innerHTML = '<div class="empty">Send a message to start.</div>';
        if (forceScroll) window.scrollTo(0, 0);
        return;
      }

      // Collapse consecutive tool calls into one Cursor-style summary.
      const blocks = [];
      for (let i = 0; i < messages.length; i++) {
        const m = messages[i];
        if ((m.kind || 'assistant') === 'tool') {
          const tools = [m];
          while (i + 1 < messages.length && (messages[i + 1].kind || '') === 'tool') {
            i++;
            tools.push(messages[i]);
          }
          blocks.push({ type: 'tools', items: tools });
        } else {
          blocks.push({ type: 'msg', item: m });
        }
      }

      const html = blocks.map(function(block, bi) {
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
          body += '<div class="steer-badge">'
            + '<svg viewBox="0 0 16 16" aria-hidden="true">'
            + '<circle cx="8" cy="8" r="6.1" fill="none" stroke="currentColor" stroke-width="1.5"/>'
            + '<circle cx="8" cy="8" r="1.55" fill="currentColor"/>'
            + '<path fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" '
            + 'd="M8 2.7v2.9M4.05 10.35l2.45-1.45M11.95 10.35l-2.45-1.45"/>'
            + '</svg>'
            + 'Steered</div>';
        }
        return '<div class="msg ' + kind + '" data-id="' + esc(m.id) + '">' + body + '</div>';
      }).join('');
      const nearBottom = (window.innerHeight + window.scrollY) >= (document.body.scrollHeight - 80);
      root.innerHTML = html;
      root.querySelectorAll('.msg.tool-group .tool-summary').forEach(function(summary) {
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
    var selToolbar = document.getElementById('sel-toolbar');

    function postSelectionChanged(text) {
      if (window.webkit && window.webkit.messageHandlers.selectionChanged) {
        window.webkit.messageHandlers.selectionChanged.postMessage({ text: text || '' });
      }
    }

    function hideSelectionToolbar() {
      pendingSelectionText = '';
      postSelectionChanged('');
      if (selToolbar) selToolbar.style.display = 'none';
    }

    function currentSelectionText() {
      var sel = window.getSelection();
      if (!sel || sel.rangeCount === 0) return '';
      return String(sel.toString() || '').trim();
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
      var text = currentSelectionText();
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
      pendingSelectionText = text;
      postSelectionChanged(text);
      selToolbar.style.display = 'flex';
      var tb = selToolbar.getBoundingClientRect();
      var left = rect.left + (rect.width / 2) - (tb.width / 2);
      var top = rect.top - tb.height - 8;
      left = Math.max(8, Math.min(left, window.innerWidth - tb.width - 8));
      if (top < 8) top = Math.min(window.innerHeight - tb.height - 8, rect.bottom + 8);
      selToolbar.style.left = left + 'px';
      selToolbar.style.top = top + 'px';
    }

    document.addEventListener('mouseup', function(e) {
      if (selToolbar && selToolbar.contains(e.target)) return;
      requestAnimationFrame(updateSelectionToolbar);
    });
    document.addEventListener('keydown', function(e) {
      if (!(e.metaKey || e.ctrlKey)) return;
      if (e.key !== 'l' && e.key !== 'L') return;
      if (e.altKey) return;
      var text = pendingSelectionText || currentSelectionText();
      if (!text) return;
      e.preventDefault();
      e.stopPropagation();
      runSelectionAction(e.shiftKey ? 'new' : 'chat');
    }, true);
    document.addEventListener('keyup', function(e) {
      if (e.key === 'Escape') {
        hideSelectionToolbar();
        return;
      }
      // Shift+arrows / keyboard selection.
      if (e.shiftKey || e.key === 'ArrowLeft' || e.key === 'ArrowRight'
          || e.key === 'ArrowUp' || e.key === 'ArrowDown') {
        requestAnimationFrame(updateSelectionToolbar);
      }
    });
    document.addEventListener('selectionchange', function() {
      if (!currentSelectionText()) hideSelectionToolbar();
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
