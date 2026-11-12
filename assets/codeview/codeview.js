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
    var copy = el('button', 'cv-icon-btn', ICON_COPY);
    copy.type = 'button';
    copy.setAttribute('aria-label', 'Copy path');
    copy.setAttribute('data-tip', 'Copy path');
    copy.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copyText;
      if (h) h.postMessage({ text: opts.path || '' });
    });
    head.appendChild(copy);
    return { head: head, seg: seg };
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
    return { root: root, body: body, seg: header.seg };
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
   * Returns a handle with dispose() / setMode(mode).
   */
  function createDiff(host, opts) {
    var mode = opts.mode || savedMode();
    var f = frame(host, {
      path: opts.path,
      fullPath: opts.fullPath,
      added: opts.added,
      removed: opts.removed,
      modes: opts.hideModes ? null : [{ id: 'inline', label: 'Inline' }, { id: 'side-by-side', label: 'Side-by-side' }]
    });
    var maxHeight = opts.maxHeight || MAX_HEIGHT;
    var handle = {
      root: f.root, disposed: false, editor: null, models: [],
      dispose: dispose, setMode: setMode, setMaxHeight: setMaxHeight, refit: null
    };
    markMode();

    if (opts.tooLarge || opts.message) {
      message(f.body, opts.message || 'Diff too large to show');
      return handle;
    }
    f.body.style.height = MIN_HEIGHT + 'px';
    f.body.classList.add('cv-loading');

    if (f.seg) {
      f.seg.addEventListener('click', function (e) {
        var b = e.target.closest('.cv-seg-btn');
        if (b) setMode(b.getAttribute('data-mode'));
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
      o.renderSideBySide = mode === 'side-by-side';
      o.useInlineViewWhenSpaceIsLimited = false;
      o.enableSplitViewResizing = false;
      o.originalEditable = false;
      o.renderIndicators = true;
      o.lineDecorationsWidth = 16;
      o.renderMarginRevertIcon = false;
      o.ignoreTrimWhitespace = false;
      o.hideUnchangedRegions = { enabled: true, contextLineCount: 3, minimumLineCount: 4, revealLineCount: 20 };
      var ed = monaco.editor.createDiffEditor(f.body, o);
      ed.setModel({ original: original, modified: modified });
      handle.editor = ed;
      var refit = function () {
        if (handle.disposed) return;
        fitHeight(f.body, [ed.getOriginalEditor(), ed.getModifiedEditor()], maxHeight);
      };
      handle.refit = refit;
      ed.onDidUpdateDiff(refit);
      ed.getModifiedEditor().onDidContentSizeChange(refit);
      ed.getOriginalEditor().onDidContentSizeChange(refit);
      refit();
    }, function () {
      if (handle.disposed) return;
      f.body.classList.remove('cv-loading');
      message(f.body, 'Couldn’t load the diff viewer');
    });

    function markMode() {
      if (!f.seg) return;
      f.seg.querySelectorAll('.cv-seg-btn').forEach(function (b) {
        var on = b.getAttribute('data-mode') === mode;
        b.classList.toggle('on', on);
        b.setAttribute('aria-pressed', on ? 'true' : 'false');
      });
    }

    function setMode(next) {
      if (next !== 'inline' && next !== 'side-by-side') return;
      mode = next;
      try { localStorage.setItem(MODE_KEY, mode); } catch (e) {}
      markMode();
      if (handle.editor) handle.editor.updateOptions({ renderSideBySide: mode === 'side-by-side' });
    }

    function setMaxHeight(n) {
      maxHeight = n || MAX_HEIGHT;
      if (handle.refit) handle.refit();
    }

    function dispose() {
      if (handle.disposed) return;
      handle.disposed = true;
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
    createDiff: createDiff,
    createEditor: createEditor,
    getSavedMode: savedMode,
    languageFor: languageFor
  };
})();
