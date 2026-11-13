/*
 * Shared markdown renderer for AiHand (chat transcript + CodeView Preview).
 * Requires global `marked` (load codeview/marked.min.js first).
 * Exposes window.AiHandMarkdown and window.markdownToHTML.
 */
(function () {
  'use strict';

  function esc(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
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

  var parse = null;

  function configure() {
    if (parse) return parse;
    if (typeof marked === 'undefined') return null;
    var api = (marked && marked.parse) ? marked : (marked.marked || marked);
    if (!api || (!api.parse && typeof api !== 'function')) return null;
    var Renderer = api.Renderer || marked.Renderer;
    var renderer = Renderer ? new Renderer() : null;
    if (renderer) {
      // Escape raw HTML tokens so tags show as text (XSS-safe; intentional).
      renderer.html = function (token) {
        var text = (token && token.text != null) ? String(token.text) : String(token || '');
        return esc(text);
      };
      renderer.code = function (token) {
        var text = (token && token.text != null) ? String(token.text) : String(token || '');
        var lang = (token && token.lang) ? String(token.lang) : '';
        var lines = text.split('\n');
        var single = lines.length <= 1 || (lines.length === 2 && lines[1] === '');
        var cls = lang ? (' class="language-' + esc(lang) + '"') : '';
        return '<div class="code-block' + (single ? ' single' : '') + '">'
          + CODE_COPY_BTN
          + '<pre><code' + cls + ' data-enhanced="1">' + esc(text) + '</code></pre></div>\n';
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
          try { api.use({ renderer: renderer }); } catch (e2) { /* keep defaults */ }
        }
      }
    } else if (api.setOptions && renderer) {
      try { api.setOptions({ renderer: renderer, gfm: true, breaks: false }); } catch (e3) { /* keep defaults */ }
    }
    parse = function (md) {
      if (api.parse) return api.parse(md, { async: false });
      if (typeof api === 'function') return api(md);
      return esc(md);
    };
    return parse;
  }

  function enhanceCodeBlocks(html) {
    return String(html).replace(/<pre><code([^>]*)>([\s\S]*?)<\/code><\/pre>/g, function (_, attrs, body) {
      if (attrs.indexOf('data-enhanced') !== -1) return '<pre><code' + attrs + '>' + body + '</code></pre>';
      var lines = body.split('\n');
      var single = lines.length <= 1 || (lines.length === 2 && lines[1] === '');
      return '<div class="code-block' + (single ? ' single' : '') + '">'
        + CODE_COPY_BTN
        + '<pre><code' + attrs + '>' + body + '</code></pre></div>';
    });
  }

  function toHTML(md) {
    if (!md) return '';
    var fn = configure();
    if (!fn) {
      // marked failed to load — show escaped plain text rather than a blank bubble.
      return '<p>' + esc(String(md)).replace(/\n/g, '<br>') + '</p>';
    }
    var html = fn(String(md));
    // Footnotes are not enabled; strip if a build ever emits them.
    html = String(html)
      .replace(/<section class="footnotes"[\s\S]*?<\/section>/gi, '')
      .replace(/<sup class="footnote-ref">[\s\S]*?<\/sup>/gi, '');
    return enhanceCodeBlocks(html);
  }

  function isMarkdownPath(path) {
    var name = String(path || '').split(/[/\\]/).pop() || '';
    var lower = name.toLowerCase();
    return /\.(md|markdown|mdown|mkd|mdx)$/.test(lower);
  }

  function bindCodeCopy(root) {
    if (!root || !root.querySelectorAll) return;
    root.querySelectorAll('.code-block .code-copy').forEach(function (btn) {
      if (btn.__mdBound) return;
      btn.__mdBound = true;
      btn.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        var block = btn.closest('.code-block');
        var code = block && block.querySelector('pre code');
        var text = code ? String(code.textContent || '') : '';
        var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copyText;
        if (h) h.postMessage({ text: text });
        else if (navigator.clipboard && navigator.clipboard.writeText) {
          try { navigator.clipboard.writeText(text); } catch (err) { /* ignore */ }
        }
        btn.classList.add('copied');
        if (btn._copyTimer) clearTimeout(btn._copyTimer);
        btn._copyTimer = setTimeout(function () {
          btn.classList.remove('copied');
          btn._copyTimer = null;
        }, 1200);
      });
    });
  }

  var api = {
    toHTML: toHTML,
    isMarkdownPath: isMarkdownPath,
    bindCodeCopy: bindCodeCopy,
    esc: esc
  };
  window.AiHandMarkdown = api;
  window.markdownToHTML = toHTML;
})();
