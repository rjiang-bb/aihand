import AppKit
import SwiftUI
import WebKit

/// Cursor-style agent transcript rendered in a WKWebView (markdown, tool cards, code).
struct ChatTranscriptView: NSViewRepresentable {
    let messages: [AgentMessage]
    var onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "tinyhand")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
#if swift(>=5.9)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
#endif
        context.coordinator.webView = webView
        webView.loadHTMLString(Self.shellHTML, baseURL: URL(fileURLWithPath: "/"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.push(messages: messages)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onSelect: (String) -> Void
        weak var webView: WKWebView?
        private var ready = false
        private var pendingMessages: [AgentMessage] = []
        private var lastPayload: String = ""
        private var imageDataURLs: [String: String] = [:]
        private var imagesSentToPage: Set<String> = []

        init(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            imagesSentToPage.removeAll()
            lastPayload = ""
            push(messages: pendingMessages)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            if type == "select", let text = body["text"] as? String, !text.isEmpty {
                onSelect(text)
            }
        }

        func push(messages: [AgentMessage]) {
            pendingMessages = messages
            guard ready, let webView else { return }

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
            if !imageLoads.isEmpty,
               let imgData = try? JSONSerialization.data(withJSONObject: imageLoads),
               let imgJSON = String(data: imgData, encoding: .utf8) {
                script += "window.cacheImages(\(imgJSON));"
            }
            script += "window.renderMessages(\(json));"
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
      .msg.tool {
        align-self: stretch;
        max-width: 100%;
        background: var(--tool-bg);
        border: 1px solid var(--tool-border);
        border-radius: 8px;
        padding: 5px 8px;
        font-size: 12px;
        color: var(--text);
        font-family: var(--mono);
        display: flex;
        gap: 6px;
        align-items: center;
        cursor: pointer;
        user-select: none;
        -webkit-user-select: none;
      }
      .msg.tool:hover { border-color: var(--link); }
      .msg.tool .chev {
        flex: none;
        width: 10px;
        color: var(--muted);
        font-size: 9px;
        line-height: 1;
        transition: transform 0.12s ease;
      }
      .msg.tool.expanded .chev { transform: rotate(90deg); }
      .msg.tool .glyph {
        flex: none;
        opacity: 0.85;
        color: var(--muted);
      }
      .msg.tool .tool-body {
        flex: 1;
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
        line-height: 1.35;
      }
      .msg.tool.expanded {
        align-items: flex-start;
        cursor: default;
        user-select: text;
        -webkit-user-select: text;
      }
      .msg.tool.expanded .tool-body {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        word-break: break-word;
        text-overflow: clip;
      }
      .msg.tool-group {
        align-self: stretch;
        max-width: 100%;
        display: flex;
        flex-direction: column;
        gap: 4px;
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
      .ask {
        margin-top: 8px;
        appearance: none;
        border: none;
        background: transparent;
        color: var(--link);
        font: 600 11px var(--sans);
        padding: 0;
        cursor: pointer;
      }
      .ask:hover { text-decoration: underline; }
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
      if (t.startsWith('writing') || t.startsWith('wrote') || t.startsWith('edit')) return '✏️';
      if (t.startsWith('ran') || t.startsWith('shell') || t.startsWith('command')) return '⌘';
      if (t.startsWith('search') || t.startsWith('grep') || t.startsWith('glob')) return '⌕';
      return '•';
    }

    function askButton(id) {
      return '<button class="ask" data-id="' + esc(id) + '">Ask about this</button>';
    }

    function toolRow(m, expanded) {
      const text = m.text || 'Tool';
      const open = expanded ? ' expanded' : '';
      return '<div class="msg tool' + open + '" data-id="' + esc(m.id) + '" data-kind="tool" role="button" aria-expanded="' + (expanded ? 'true' : 'false') + '">'
        + '<span class="chev">▶</span>'
        + '<span class="glyph">' + toolGlyph(text) + '</span>'
        + '<span class="tool-body" title="' + esc(text) + '">' + esc(text) + '</span>'
        + '</div>';
    }

    window.__texts = {};
    window.__images = window.__images || {};
    window.__expandedTools = window.__expandedTools || {};
    window.cacheImages = function(items) {
      (items || []).forEach(function(item) {
        if (item && item.key && item.url) window.__images[item.key] = item.url;
      });
    };
    window.renderMessages = function(messages) {
      const root = document.getElementById('root');
      window.__texts = {};
      if (!messages || !messages.length) {
        root.innerHTML = '<div class="empty">Agent replies show up here.</div>';
        return;
      }

      // Group consecutive tool calls into a compact stack (Cursor-style).
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

      const html = blocks.map(function(block) {
        if (block.type === 'tools') {
          const rows = block.items.map(function(m) {
            window.__texts[m.id] = m.text || '';
            return toolRow(m, !!window.__expandedTools[m.id]);
          }).join('');
          return '<div class="msg tool-group">' + rows + '</div>';
        }
        const m = block.item;
        const kind = m.kind || 'assistant';
        window.__texts[m.id] = m.text || '';
        let body = '';
        const image = m.image || (m.imageKey ? window.__images[m.imageKey] : null);
        if (image) {
          body += '<img class="shot" src="' + image + '" alt="Screenshot">';
        }
        if (kind === 'assistant') {
          body += '<div class="md">' + markdownToHTML(m.text || '') + '</div>';
          if (m.text) body += askButton(m.id);
        } else if (kind === 'user') {
          body += '<div class="md">' + markdownToHTML(m.text || '') + '</div>';
          if (m.text) body += askButton(m.id);
        } else {
          body += esc(m.text || '');
        }
        return '<div class="msg ' + kind + '" data-id="' + esc(m.id) + '">' + body + '</div>';
      }).join('');
      const nearBottom = (window.innerHeight + window.scrollY) >= (document.body.scrollHeight - 80);
      root.innerHTML = html;
      root.querySelectorAll('button.ask').forEach(function(btn) {
        btn.addEventListener('click', function(e) {
          e.preventDefault();
          const id = btn.getAttribute('data-id');
          const text = (window.__texts[id] || '').trim();
          if (!text) return;
          const selected = String(window.getSelection() || '').trim();
          window.webkit.messageHandlers.tinyhand.postMessage({
            type: 'select',
            text: (selected && text.indexOf(selected) !== -1) ? selected : text
          });
        });
      });
      root.querySelectorAll('.msg.tool').forEach(function(el) {
        el.addEventListener('click', function(e) {
          e.preventDefault();
          const id = el.getAttribute('data-id');
          const next = !el.classList.contains('expanded');
          el.classList.toggle('expanded', next);
          el.setAttribute('aria-expanded', next ? 'true' : 'false');
          if (id) window.__expandedTools[id] = next;
        });
      });
      if (nearBottom) {
        window.scrollTo(0, document.body.scrollHeight);
      }
    };
    </script>
    </body>
    </html>
    """
}
