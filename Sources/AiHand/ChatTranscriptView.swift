import AppKit
import SwiftUI
import WebKit

/// Cursor-style agent transcript rendered in a WKWebView (markdown, tool cards, code).
struct ChatTranscriptView: NSViewRepresentable {
    let messages: [AgentMessage]
    var sessionID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let uc = config.userContentController
        uc.add(context.coordinator, name: "openImage")
        uc.add(context.coordinator, name: "imageMenu")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
#if swift(>=5.9)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
#endif
        context.coordinator.webView = webView
        context.coordinator.pendingSessionID = sessionID
        webView.loadHTMLString(Self.shellHTML, baseURL: URL(fileURLWithPath: "/"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.push(messages: messages, sessionID: sessionID)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let uc = webView.configuration.userContentController
        uc.removeScriptMessageHandler(forName: "openImage")
        uc.removeScriptMessageHandler(forName: "imageMenu")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
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

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let key = body["key"] as? String,
                  !key.isEmpty,
                  FileManager.default.fileExists(atPath: key) else { return }

            switch message.name {
            case "openImage":
                ChatImageActions.open(path: key)
            case "imageMenu":
                guard let webView else { return }
                let clientX = CGFloat((body["x"] as? Double) ?? (body["x"] as? Int).map(Double.init) ?? 0)
                let clientY = CGFloat((body["y"] as? Double) ?? (body["y"] as? Int).map(Double.init) ?? 0)
                // WKWebView is flipped — JS client coords already match view coords.
                let y = webView.isFlipped ? clientY : (webView.bounds.height - clientY)
                let point = NSPoint(x: clientX, y: y)
                ChatImageActions.showMenu(path: key, at: point, in: webView)
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
                if let path = msg.imagePath {
                    dict["imageKey"] = path
                    if imageDataURLs[path] == nil,
                       let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                        let mime = path.lowercased().hasSuffix(".jpg") || path.lowercased().hasSuffix(".jpeg")
                            ? "image/jpeg" : "image/png"
                        imageDataURLs[path] = "data:\(mime);base64,\(data.base64EncodedString())"
                    }
                    if let url = imageDataURLs[path], !imagesSentToPage.contains(path) {
                        imagesSentToPage.insert(path)
                        imageLoads.append(["key": path, "url": url])
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
        font: 13.5px/1.55 var(--sans);
        -webkit-user-select: text;
        user-select: text;
      }
      #root {
        padding: 14px 16px 24px;
        display: flex;
        flex-direction: column;
        gap: 14px;
      }
      .msg { max-width: 100%; }
      .msg.user {
        align-self: flex-end;
        max-width: 88%;
        background: var(--user-bg);
        border: 1px solid var(--user-border);
        border-radius: 14px;
        padding: 10px 12px;
        color: var(--text);
      }
      .msg.assistant { align-self: stretch; padding: 2px 0; color: var(--text); }
      .msg.tool-group {
        align-self: stretch;
        max-width: 100%;
        font: 12.5px/1.45 var(--sans);
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
        font-size: 11.5px;
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
        font-size: 11px;
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
        font-size: 12px;
        color: var(--text);
      }
      .msg img.shot {
        display: block;
        max-width: min(280px, 100%);
        max-height: 180px;
        border-radius: 8px;
        margin-bottom: 8px;
        object-fit: contain;
        cursor: zoom-in;
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
      .md ul, .md ol { margin: 0.45em 0; padding-left: 1.35em; }
      .md li { margin: 0.2em 0; }
      .md a { color: var(--link); }
      .md code {
        font-family: var(--mono);
        font-size: 0.9em;
        background: var(--code-bg);
        padding: 0.12em 0.35em;
        border-radius: 4px;
      }
      .md pre {
        background: var(--pre-bg);
        border: 1px solid var(--border);
        border-radius: 10px;
        padding: 10px 12px;
        overflow-x: auto;
        margin: 0.7em 0;
      }
      .md pre code {
        background: none;
        padding: 0;
        font-size: 12px;
        line-height: 1.45;
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
        font-size: 12.5px;
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
        font-size: 13px;
      }
    </style>
    </head>
    <body>
    <div id="root"></div>
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
      return s;
    }

    function markdownToHTML(md) {
      if (!md) return '';
      const lines = String(md).replace(/\\r\\n?/g, '\\n').split('\\n');
      const out = [];
      let i = 0;
      let inUl = false, inOl = false, inPara = false;

      function closeLists() {
        if (inUl) { out.push('</ul>'); inUl = false; }
        if (inOl) { out.push('</ol>'); inOl = false; }
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
          out.push('<pre><code class="lang-' + esc(lang) + '">' + esc(buf.join('\\n')) + '</code></pre>');
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

        const ul = line.match(/^\\s*[-*]\\s+(.+)$/);
        if (ul) {
          closePara();
          if (inOl) { out.push('</ol>'); inOl = false; }
          if (!inUl) { out.push('<ul>'); inUl = true; }
          out.push('<li>' + inlineMarkdown(ul[1]) + '</li>');
          i++; continue;
        }

        const ol = line.match(/^\\s*(\\d+)\\.\\s+(.+)$/);
        if (ol) {
          closePara();
          if (inUl) { out.push('</ul>'); inUl = false; }
          if (!inOl) { out.push('<ol>'); inOl = true; }
          out.push('<li>' + inlineMarkdown(ol[2]) + '</li>');
          i++; continue;
        }

        if (/^\\s*$/.test(line)) {
          closePara(); closeLists();
          i++; continue;
        }

        closeLists();
        if (!inPara) { out.push('<p>'); inPara = true; }
        else { out.push('<br>'); }
        out.push(inlineMarkdown(line));
        i++;
      }
      closePara(); closeLists();
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
        const image = m.image || (m.imageKey ? window.__images[m.imageKey] : null);
        if (image) {
          const keyAttr = m.imageKey ? ' data-key="' + esc(m.imageKey) + '"' : '';
          body += '<img class="shot" src="' + image + '"' + keyAttr + ' alt="Screenshot" title="Click to open · Right-click to copy">';
        }
        if (kind === 'assistant' || kind === 'user') {
          body += '<div class="md">' + markdownToHTML(m.text || '') + '</div>';
        } else {
          body += esc(m.text || '');
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
      root.querySelectorAll('img.shot[data-key]').forEach(function(img) {
        img.addEventListener('click', function(e) {
          e.preventDefault();
          e.stopPropagation();
          var key = img.getAttribute('data-key');
          if (key && window.webkit && window.webkit.messageHandlers.openImage) {
            window.webkit.messageHandlers.openImage.postMessage({ key: key });
          }
        });
        img.addEventListener('contextmenu', function(e) {
          e.preventDefault();
          e.stopPropagation();
          var key = img.getAttribute('data-key');
          if (key && window.webkit && window.webkit.messageHandlers.imageMenu) {
            window.webkit.messageHandlers.imageMenu.postMessage({
              key: key,
              x: e.clientX,
              y: e.clientY
            });
          }
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
    };
    </script>
    </body>
    </html>
    """
}
