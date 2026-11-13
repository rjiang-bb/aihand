/*
 * CodeView — shared Monaco chrome for AiHand (diffs in chat today, a file editor later).
 * Loaded by the transcript shell from aihand-asset://app/codeview/codeview.js.
 * Monaco itself loads lazily from aihand-asset://app/monaco/vs on first use.
 */
(function () {
  'use strict';

  var MAX_HEIGHT = 420;
  var MIN_HEIGHT = 54;
  var MODE_KEY = 'aihand.codeview.diffMode';
  var loading = null;

  function vsBase() {
    return new URL('monaco/vs', document.baseURI).href;
  }

  function loadMonaco() {
    if (window.monaco && window.monaco.editor) return Promise.resolve(window.monaco);
    if (loading) return loading;
    loading = new Promise(function (resolve, reject) {
      var vs = vsBase();
      // Same-origin worker (the shell's base URL is the asset scheme). If WebKit refuses it,
      // Monaco falls back to computing diffs on the main thread.
      window.MonacoEnvironment = {
        getWorkerUrl: function () { return vs + '/base/worker/workerMain.js'; }
      };
      var css = document.createElement('link');
      css.rel = 'stylesheet';
      css.href = vs + '/editor/editor.main.css';
      document.head.appendChild(css);
      var s = document.createElement('script');
      s.src = vs + '/loader.js';
      s.onerror = function () { loading = null; reject(new Error('Monaco loader failed')); };
      s.onload = function () {
        try {
          window.require.config({ paths: { vs: vs } });
          window.require(['vs/editor/editor.main'], function () {
            configure(window.monaco);
            resolve(window.monaco);
          }, function (err) { loading = null; reject(err); });
        } catch (e) {
          loading = null;
          reject(e);
        }
      };
      document.head.appendChild(s);
    });
    return loading;
  }

  function quiet(fn) { try { fn(); } catch (e) { /* language contribution missing */ } }

  function configure(monaco) {
    // Snippets and partial files: no squiggles, hovers, or suggestion noise.
    quiet(function () {
      var ts = monaco.languages.typescript;
      var off = { noSemanticValidation: true, noSyntaxValidation: true, noSuggestionDiagnostics: true };
      ts.typescriptDefaults.setDiagnosticsOptions(off);
      ts.javascriptDefaults.setDiagnosticsOptions(off);
    });
    quiet(function () { monaco.languages.json.jsonDefaults.setDiagnosticsOptions({ validate: false }); });
    quiet(function () {
      ['cssDefaults', 'scssDefaults', 'lessDefaults'].forEach(function (k) {
        monaco.languages.css[k].setOptions({ validate: false });
      });
    });

    monaco.editor.defineTheme('aihand-dark', {
      base: 'vs-dark',
      inherit: true,
      rules: [],
      colors: {
        'editor.background': '#1c1c1e',
        'editorGutter.background': '#1c1c1e',
        'editorLineNumber.foreground': '#6e6e73',
        'editorLineNumber.activeForeground': '#a1a1a6',
        'diffEditor.insertedLineBackground': '#2ea04326',
        'diffEditor.insertedTextBackground': '#2ea04340',
        'diffEditor.removedLineBackground': '#f8514926',
        'diffEditor.removedTextBackground': '#f8514940',
        'diffEditor.diagonalFill': '#00000000',
        'diffEditor.unchangedRegionBackground': '#242426',
        'scrollbarSlider.background': '#ffffff1f'
      }
    });
    monaco.editor.defineTheme('aihand-light', {
      base: 'vs',
      inherit: true,
      rules: [],
      colors: {
        'editor.background': '#ffffff',
        'editorGutter.background': '#ffffff',
        'editorLineNumber.foreground': '#a1a1a6',
        'diffEditor.insertedLineBackground': '#1a7f3714',
        'diffEditor.insertedTextBackground': '#1a7f3730',
        'diffEditor.removedLineBackground': '#cf222e14',
        'diffEditor.removedTextBackground': '#cf222e30',
        'diffEditor.diagonalFill': '#00000000',
        'diffEditor.unchangedRegionBackground': '#f5f5f7'
      }
    });
    var mq = window.matchMedia('(prefers-color-scheme: light)');
    var apply = function () { monaco.editor.setTheme(mq.matches ? 'aihand-light' : 'aihand-dark'); };
    apply();
    if (mq.addEventListener) mq.addEventListener('change', apply);
  }

  function languageFor(monaco, path) {
    var name = String(path || '').split('/').pop() || '';
    var lower = name.toLowerCase();
    var dot = lower.lastIndexOf('.');
    var ext = dot >= 0 ? lower.slice(dot) : '';
    var langs = monaco.languages.getLanguages();
    for (var i = 0; i < langs.length; i++) {
      var l = langs[i];
      if ((l.filenames || []).some(function (f) { return f.toLowerCase() === lower; })) return l.id;
    }
    if (ext) {
      for (var j = 0; j < langs.length; j++) {
        if ((langs[j].extensions || []).some(function (e) { return e.toLowerCase() === ext; })) return langs[j].id;
      }
    }
    return 'plaintext';
  }

  function isMarkdownPath(path) {
    if (window.AiHandMarkdown && window.AiHandMarkdown.isMarkdownPath) {
      return window.AiHandMarkdown.isMarkdownPath(path);
    }
    var name = String(path || '').split(/[/\\]/).pop() || '';
    return /\.(md|markdown|mdown|mkd|mdx)$/i.test(name);
  }

  var mdLoading = null;
  function ensureMarkdownCSS() {
    if (document.getElementById('cv-markdown-css')) return;
    var link = document.createElement('link');
    link.id = 'cv-markdown-css';
    link.rel = 'stylesheet';
    link.href = new URL('codeview/markdown.css', document.baseURI).href;
    document.head.appendChild(link);
  }

  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = new URL(src, document.baseURI).href;
      s.onload = function () { resolve(); };
      s.onerror = function () { reject(new Error('Failed to load ' + src)); };
      document.head.appendChild(s);
    });
  }

  function loadMarkdown() {
    if (window.AiHandMarkdown && window.AiHandMarkdown.toHTML) {
      ensureMarkdownCSS();
      return Promise.resolve(window.AiHandMarkdown);
    }
    if (mdLoading) return mdLoading;
    ensureMarkdownCSS();
    mdLoading = (window.marked
      ? Promise.resolve()
      : loadScript('codeview/marked.min.js')
    ).then(function () {
      if (window.AiHandMarkdown && window.AiHandMarkdown.toHTML) return window.AiHandMarkdown;
      return loadScript('codeview/markdown.js').then(function () { return window.AiHandMarkdown; });
    }).then(function (api) {
      if (!api || !api.toHTML) throw new Error('markdown renderer missing');
      return api;
    }).catch(function (err) {
      mdLoading = null;
      throw err;
    });
    return mdLoading;
  }

  function baseOptions(lineOffset) {
    var offset = lineOffset || 0;
    var opts = {
      readOnly: true,
      domReadOnly: true,
      automaticLayout: true,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      renderOverviewRuler: false,
      overviewRulerLanes: 0,
      overviewRulerBorder: false,
      hideCursorInOverviewRuler: true,
      renderLineHighlight: 'none',
      renderValidationDecorations: 'off',
      contextmenu: false,
      hover: { enabled: false },
      quickSuggestions: false,
      folding: false,
      glyphMargin: false,
      lineDecorationsWidth: 6,
      lineNumbersMinChars: 3,
      stickyScroll: { enabled: false },
      occurrencesHighlight: 'off',
      selectionHighlight: false,
      links: false,
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
      fontSize: 12,
      lineHeight: 18,
      padding: { top: 4, bottom: 4 },
      scrollbar: {
        alwaysConsumeMouseWheel: false,
        verticalScrollbarSize: 8,
        horizontalScrollbarSize: 8,
        useShadows: false
      }
    };
    if (offset) opts.lineNumbers = function (n) { return String(n + offset); };
    return opts;
  }

  var ICON_FILE = '<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="none" stroke="currentColor" '
    + 'stroke-width="1.3" stroke-linejoin="round" d="M4 1.75h5.2L12.5 5v9.25H4z"/>'
    + '<path fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" d="M9 1.9V5.2h3.3"/></svg>';
  var ICON_COPY = '<svg viewBox="0 0 16 16" aria-hidden="true">'
    + '<rect x="5.5" y="5.5" width="8" height="8" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.3"/>'
    + '<path fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" d="M3.5 10.5V3.8A1.3 1.3 0 0 1 4.8 2.5h6.7"/></svg>';

  var ICON_CHECK = '<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="none" stroke="currentColor" '
    + 'stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" d="M3.5 8.5l3 3 6-7"/></svg>';

  function el(tag, cls, html) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (html != null) n.innerHTML = html;
    return n;
  }

  function shortPath(path) {
    var parts = String(path || '').split('/').filter(Boolean);
    return parts.length > 3 ? '…/' + parts.slice(-3).join('/') : String(path || '');
  }

  /** Shared header used by diffs and editors so both look the same. */
  function buildHeader(opts) {
    var head = el('div', 'cv-head');
    head.appendChild(el('span', 'cv-icon', ICON_FILE));
    var p = el('span', 'cv-path');
    p.textContent = opts.fullPath ? String(opts.path || '') : shortPath(opts.path);
    p.title = opts.path || '';
    head.appendChild(p);
    if (opts.added || opts.removed) {
      var st = el('span', 'cv-stats');
      if (opts.added) st.appendChild(el('span', 'diff-add', '+' + opts.added));
      if (opts.removed) st.appendChild(el('span', 'diff-del', '-' + opts.removed));
      head.appendChild(st);
    }
    head.appendChild(el('span', 'cv-spacer'));
    var seg = null;
    if (opts.modes) {
      seg = el('div', 'cv-seg');
      seg.setAttribute('role', 'group');
      opts.modes.forEach(function (m) {
        var b = el('button', 'cv-seg-btn');
        b.type = 'button';
        b.textContent = m.label;
        b.setAttribute('data-mode', m.id);
        seg.appendChild(b);
      });
      head.appendChild(seg);
    }
    var previewBtn = null;
    if (opts.previewable) {
      previewBtn = el('button', 'cv-seg-btn cv-preview-btn');
      previewBtn.type = 'button';
      previewBtn.textContent = 'Preview';
      previewBtn.setAttribute('aria-pressed', 'false');
      previewBtn.setAttribute('data-tip', 'Preview markdown');
      var previewWrap = el('div', 'cv-seg');
      previewWrap.appendChild(previewBtn);
      head.appendChild(previewWrap);
    }
    var copy = el('button', 'cv-icon-btn', ICON_COPY);
    copy.type = 'button';
    copy.setAttribute('aria-label', 'Copy path');
    copy.setAttribute('data-tip', 'Copy path');
    copy.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copyText;
      if (h) h.postMessage({ text: opts.path || '' });
      // Checkmark feedback, then back to the copy glyph.
      clearTimeout(copy.__t);
      copy.innerHTML = ICON_CHECK;
      copy.classList.add('done');
      copy.setAttribute('data-tip', 'Copied');
      copy.__t = setTimeout(function () {
        copy.innerHTML = ICON_COPY;
        copy.classList.remove('done');
        copy.setAttribute('data-tip', 'Copy path');
      }, 1300);
    });
    head.appendChild(copy);
    return { head: head, seg: seg, previewBtn: previewBtn };
  }

  function frame(host, opts) {
    host.innerHTML = '';
    var root = el('div', 'cv');
    var header = buildHeader(opts);
    root.appendChild(header.head);
    var body = el('div', 'cv-body');
    root.appendChild(body);
    host.appendChild(root);
    // Clicks inside the viewer must not toggle the transcript rows around it.
    root.addEventListener('click', function (e) { e.stopPropagation(); });
    return { root: root, body: body, seg: header.seg, previewBtn: header.previewBtn };
  }

  function message(body, text) {
    body.classList.add('cv-message');
    body.textContent = text;
  }

  function fitHeight(body, editors, max) {
    var h = 0;
    editors.forEach(function (ed) { h = Math.max(h, ed.getContentHeight()); });
    body.style.height = Math.max(MIN_HEIGHT, Math.min(max || MAX_HEIGHT, h)) + 'px';
  }

  function savedMode() {
    try { return localStorage.getItem(MODE_KEY) === 'side-by-side' ? 'side-by-side' : 'inline'; } catch (e) { return 'inline'; }
  }

  /**
   * Diff viewer. opts: { path, original, modified, lineOffset, mode, added, removed, tooLarge }.
   * Returns a handle with dispose() / setMode(mode) / setPreview(on).
   */
  function createDiff(host, opts) {
    var mode = opts.mode || savedMode();
    var previewable = opts.previewable != null ? !!opts.previewable : isMarkdownPath(opts.path);
    var previewing = !!opts.preview;
    var f = frame(host, {
      path: opts.path,
      fullPath: opts.fullPath,
      added: opts.added,
      removed: opts.removed,
      modes: opts.hideModes ? null : [{ id: 'inline', label: 'Inline' }, { id: 'side-by-side', label: 'Side-by-side' }],
      previewable: previewable
    });
    var maxHeight = opts.maxHeight || MAX_HEIGHT;
    var monacoHost = null;
    var previewHost = null;
    var handle = {
      root: f.root, disposed: false, editor: null, models: [],
      dispose: dispose, setMode: setMode, setPreview: setPreview, setMaxHeight: setMaxHeight,
      refit: null, ready: null, previewing: function () { return previewing; }
    };
    // Resolves once the first diff is laid out (or immediately for message-only bodies) so callers
    // can mount many diffs one at a time without freezing the page.
    var readyDone;
    handle.ready = new Promise(function (resolve) { readyDone = resolve; });
    markMode();
    markPreview();

    if (opts.tooLarge || opts.message) {
      message(f.body, opts.message || 'Diff too large to show');
      readyDone();
      return handle;
    }

    monacoHost = el('div', 'cv-monaco');
    previewHost = el('div', 'cv-md md');
    previewHost.hidden = true;
    f.body.appendChild(monacoHost);
    f.body.appendChild(previewHost);
    monacoHost.style.height = MIN_HEIGHT + 'px';
    f.body.style.height = MIN_HEIGHT + 'px';
    f.body.classList.add('cv-loading');

    if (f.seg) {
      f.seg.addEventListener('click', function (e) {
        var b = e.target.closest('.cv-seg-btn');
        if (b) setMode(b.getAttribute('data-mode'));
      });
    }
    if (f.previewBtn) {
      f.previewBtn.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        setPreview(!previewing);
      });
    }

    loadMonaco().then(function (monaco) {
      if (handle.disposed) return;
      f.body.classList.remove('cv-loading');
      var lang = opts.language || languageFor(monaco, opts.path);
      var original = monaco.editor.createModel(opts.original || '', lang);
      var modified = monaco.editor.createModel(opts.modified || '', lang);
      handle.models = [original, modified];
      var o = baseOptions(opts.lineOffset);
      // Inline mode draws original + modified numbers in adjacent columns: size each one digit wider
      // than the longest number so e.g. 261/261 never reads as "261261".
      var lineCount = function (t) { return String(t || '').split('\n').length; };
      var maxLine = Math.max(lineCount(opts.original), lineCount(opts.modified)) + (opts.lineOffset || 0);
      o.lineNumbersMinChars = Math.max(3, String(maxLine).length + 1);
      o.renderSideBySide = mode === 'side-by-side';
      o.useInlineViewWhenSpaceIsLimited = false;
      o.enableSplitViewResizing = false;
      o.originalEditable = false;
      o.renderIndicators = true;
      o.lineDecorationsWidth = 16;
      o.renderMarginRevertIcon = false;
      o.ignoreTrimWhitespace = false;
      o.hideUnchangedRegions = { enabled: true, contextLineCount: 3, minimumLineCount: 4, revealLineCount: 20 };
      var ed = monaco.editor.createDiffEditor(monacoHost, o);
      ed.setModel({ original: original, modified: modified });
      handle.editor = ed;
      var refit = function () {
        if (handle.disposed || previewing) return;
        fitHeight(monacoHost, [ed.getOriginalEditor(), ed.getModifiedEditor()], maxHeight);
        f.body.style.height = monacoHost.style.height;
      };
      handle.refit = refit;
      ed.onDidUpdateDiff(refit);
      ed.onDidUpdateDiff(function () { readyDone(); });
      setTimeout(readyDone, 2500);
      ed.getModifiedEditor().onDidContentSizeChange(refit);
      ed.getOriginalEditor().onDidContentSizeChange(refit);
      if (previewing) applyPreview(true);
      else refit();
    }, function () {
      if (handle.disposed) return;
      f.body.classList.remove('cv-loading');
      message(f.body, 'Couldn’t load the diff viewer');
      readyDone();
    });

    function markMode() {
      if (!f.seg) return;
      f.seg.querySelectorAll('.cv-seg-btn').forEach(function (b) {
        var on = b.getAttribute('data-mode') === mode;
        b.classList.toggle('on', on);
        b.setAttribute('aria-pressed', on ? 'true' : 'false');
      });
      if (f.seg) f.seg.hidden = !!previewing;
    }

    function markPreview() {
      if (!f.previewBtn) return;
      f.previewBtn.classList.toggle('on', previewing);
      f.previewBtn.setAttribute('aria-pressed', previewing ? 'true' : 'false');
    }

    function previewSource() {
      // Prefer the current (modified) side; for pure deletes preview what was removed.
      if (typeof opts.modified === 'string') {
        if (opts.modified === '' && opts.original) return String(opts.original);
        return opts.modified;
      }
      return String(opts.original || '');
    }

    function fitPreview() {
      if (!previewHost || handle.disposed) return;
      previewHost.style.height = 'auto';
      previewHost.style.overflow = 'visible';
      var h = Math.max(MIN_HEIGHT, Math.min(maxHeight, previewHost.scrollHeight + 4));
      f.body.style.height = h + 'px';
      f.body.style.overflow = 'auto';
      previewHost.style.height = '';
    }

    function applyPreview(on) {
      previewing = !!on;
      markPreview();
      markMode();
      f.body.classList.toggle('cv-preview', previewing);
      if (monacoHost) monacoHost.hidden = previewing;
      if (previewHost) previewHost.hidden = !previewing;
      if (!previewing) {
        f.body.style.overflow = '';
        if (handle.refit) handle.refit();
        return;
      }
      f.body.classList.add('cv-loading');
      loadMarkdown().then(function (md) {
        if (handle.disposed || !previewing) return;
        f.body.classList.remove('cv-loading');
        previewHost.innerHTML = md.toHTML(previewSource());
        md.bindCodeCopy(previewHost);
        fitPreview();
        readyDone();
      }, function () {
        if (handle.disposed || !previewing) return;
        f.body.classList.remove('cv-loading');
        previewHost.textContent = 'Couldn’t load the markdown preview';
        fitPreview();
        readyDone();
      });
    }

    function setPreview(on) {
      if (!previewable) return;
      applyPreview(!!on);
    }

    function setMode(next) {
      if (next !== 'inline' && next !== 'side-by-side') return;
      if (previewing) setPreview(false);
      mode = next;
      try { localStorage.setItem(MODE_KEY, mode); } catch (e) {}
      markMode();
      if (handle.editor) handle.editor.updateOptions({ renderSideBySide: mode === 'side-by-side' });
    }

    function setMaxHeight(n) {
      maxHeight = n || MAX_HEIGHT;
      if (previewing) fitPreview();
      else if (handle.refit) handle.refit();
    }

    function dispose() {
      if (handle.disposed) return;
      handle.disposed = true;
      readyDone();
      if (handle.editor) handle.editor.dispose();
      handle.models.forEach(function (m) { m.dispose(); });
      handle.editor = null;
      handle.models = [];
    }

    return handle;
  }

  /** File editor with the same chrome (used by the upcoming editor surface). */
  function createEditor(host, opts) {
    var f = frame(host, { path: opts.path });
    var handle = { root: f.root, disposed: false, editor: null, model: null, dispose: dispose };
    f.body.style.height = MIN_HEIGHT + 'px';
    loadMonaco().then(function (monaco) {
      if (handle.disposed) return;
      var lang = opts.language || languageFor(monaco, opts.path);
      handle.model = monaco.editor.createModel(opts.value || '', lang);
      var o = baseOptions(0);
      o.readOnly = opts.readOnly !== false;
      o.domReadOnly = o.readOnly;
      o.model = handle.model;
      var ed = monaco.editor.create(f.body, o);
      handle.editor = ed;
      if (opts.height) {
        f.body.style.height = opts.height + 'px';
      } else {
        var refit = function () { fitHeight(f.body, [ed]); };
        ed.onDidContentSizeChange(refit);
        refit();
      }
    }, function () {
      if (!handle.disposed) message(f.body, 'Couldn’t load the editor');
    });
    function dispose() {
      if (handle.disposed) return;
      handle.disposed = true;
      if (handle.editor) handle.editor.dispose();
      if (handle.model) handle.model.dispose();
    }
    return handle;
  }

  window.CodeView = {
    loadMonaco: loadMonaco,
    loadMarkdown: loadMarkdown,
    createDiff: createDiff,
    createEditor: createEditor,
    getSavedMode: savedMode,
    languageFor: languageFor,
    isMarkdownPath: isMarkdownPath
  };
})();
