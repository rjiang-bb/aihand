/*
 * Worktree Changes window UI (read-only). Native side answers `changes` messages:
 *   files / counts / commits / content  →  Changes.receive(id, payload)
 * Diffs are rendered through CodeView.createDiff (never monaco.editor.* directly).
 */
(function () {
  'use strict';

  var post = function (msg) {
    var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.changes;
    if (h) h.postMessage(msg);
  };

  var nextId = 1;
  var pending = {};
  function call(op, payload, cb) {
    var id = nextId++;
    pending[id] = cb;
    var msg = { op: op, id: id };
    Object.keys(payload || {}).forEach(function (k) { msg[k] = payload[k]; });
    post(msg);
  }

  var $ = function (id) { return document.getElementById(id); };
  function el(tag, cls, html) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (html != null) n.innerHTML = html;
    return n;
  }
  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  var ICON = {
    uncommitted: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path stroke-linecap="round" d="M3.5 10.5V3.8A1.3 1.3 0 0 1 4.8 2.5h6.7"/></svg>',
    staged: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><rect x="2.5" y="2.5" width="11" height="11" rx="2"/><path d="M8 5.5v5M5.5 8h5"/></svg>',
    unstaged: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><rect x="2.5" y="2.5" width="11" height="11" rx="2"/><path d="M5 11l6-6"/></svg>',
    commits: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><circle cx="8" cy="8" r="2.5"/><path d="M8 2v3.5M8 10.5V14"/></svg>',
    chev: '<svg class="chev" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6l4 4 4-4"/></svg>',
    right: '<svg class="chev" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 4l4 4-4 4"/></svg>',
    tick: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5l3 3 6-7"/></svg>'
  };

  var LABEL = { uncommitted: 'Uncommitted', staged: 'Staged', unstaged: 'Unstaged' };
  var PAGE = 50;

  var S = {
    context: { branch: '', path: '' },
    filter: { kind: 'uncommitted' },
    files: [],
    selected: null,
    counts: null,
    commits: [],
    commitsDone: false,
    commitsOpen: false,
    mode: 'inline',
    loadSeq: 0,
    slots: [],
    observer: null,
    far: null,
    menuOpen: false,
    query: '',
    sideWidth: 0
  };

  function visibleFiles() {
    var terms = S.query.toLowerCase().split(/\s+/).filter(Boolean);
    if (!terms.length) return S.files;
    return S.files.filter(function (f) {
      var p = f.path.toLowerCase();
      return terms.every(function (t) { return p.indexOf(t) >= 0; });
    });
  }

  function statHTML(added, removed) {
    var h = '';
    if (added) h += '<span class="add">+' + added + '</span>';
    if (removed) h += '<span class="del">-' + removed + '</span>';
    return h ? '<span class="stat">' + h + '</span>' : '';
  }

  /** "4 hours ago" -> "4h" so the date never gets clipped in the flyout. */
  function shortAgo(text) {
    var m = String(text || '').match(/^(\d+)\s+(second|minute|hour|day|week|month|year)s?\s+ago$/);
    if (!m) return String(text || '');
    var unit = { second: 's', minute: 'm', hour: 'h', day: 'd', week: 'w', month: 'mo', year: 'y' }[m[2]];
    return m[1] + unit;
  }

  function filterKey(f) { return f.kind === 'commit' ? 'commit:' + f.sha : f.kind; }

  // ---------- header ----------
  function renderBar() {
    var f = S.filter;
    var label;
    var icon;
    if (f.kind === 'commit') {
      label = '<span class="muted">' + esc(f.short || f.sha.slice(0, 7)) + '</span> ' + esc(f.subject || 'Commit');
      icon = ICON.commits;
    } else {
      label = LABEL[f.kind];
      icon = ICON[f.kind];
    }
    var c = S.counts && S.counts[f.kind];
    $('filterBtn').innerHTML = icon + '<span>' + label + '</span>' + (c ? statHTML(c.insertions, c.deletions) : '') + ICON.chev;
    $('filterBtn').classList.toggle('open', S.menuOpen);
    $('branch').textContent = S.context.branch || '';
    $('branch').title = S.context.path || '';
    document.querySelectorAll('#modeSeg button').forEach(function (b) {
      b.classList.toggle('on', b.getAttribute('data-mode') === S.mode);
    });
  }

  function renderMenu() {
    var menu = $('menu');
    menu.hidden = !S.menuOpen;
    if (!S.menuOpen) return;
    menu.innerHTML = '';
    ['uncommitted', 'staged', 'unstaged'].forEach(function (k) {
      var b = el('button', 'mi');
      b.type = 'button';
      b.setAttribute('data-filter', k);
      var c = S.counts && S.counts[k];
      b.innerHTML = ICON[k] + '<span class="label">' + LABEL[k] + '</span>'
        + (c ? statHTML(c.insertions, c.deletions) : '')
        + '<span class="tick">' + (S.filter.kind === k ? ICON.tick : '') + '</span>';
      b.addEventListener('click', function () { setFilter({ kind: k }); });
      menu.appendChild(b);
    });
    // Commits opens a flyout to the right on hover (click also opens it).
    var sub = el('div', 'sub');
    var cm = el('button', 'mi');
    cm.type = 'button';
    cm.setAttribute('data-filter', 'commits');
    cm.innerHTML = ICON.commits + '<span class="label">Commits</span>'
      + '<span class="tick">' + (S.filter.kind === 'commit' ? ICON.tick : '') + '</span>' + ICON.right;
    sub.appendChild(cm);
    sub.addEventListener('mouseenter', function () { openCommits(true); });
    sub.addEventListener('mouseleave', function () { openCommits(false); });
    cm.addEventListener('click', function () { openCommits(true, true); });

    var list = el('div', 'commits fly');
    list.hidden = !S.commitsOpen;
    if (S.commitsOpen) {
      if (!S.commits.length) {
        list.appendChild(el('div', 'note', S.commitsDone ? 'No commits' : 'Loading…'));
      }
      S.commits.forEach(function (c) {
        var b = el('button', 'mi commit');
        b.type = 'button';
        b.setAttribute('data-sha', c.sha);
        b.innerHTML = '<span class="sha">' + esc(c.short) + '</span><span class="label">' + esc(c.subject)
          + '</span><span class="when" title="' + esc(c.date) + '">' + esc(shortAgo(c.date)) + '</span>';
        if (S.filter.kind === 'commit' && S.filter.sha === c.sha) b.classList.add('on');
        b.addEventListener('click', function () {
          setFilter({ kind: 'commit', sha: c.sha, short: c.short, subject: c.subject });
        });
        list.appendChild(b);
      });
      if (S.commits.length && !S.commitsDone) {
        var more = el('button', 'mi');
        more.type = 'button';
        more.innerHTML = '<span class="label muted">Load more…</span>';
        more.addEventListener('click', loadCommits);
        list.appendChild(more);
      }
    }
    sub.appendChild(list);
    menu.appendChild(sub);
  }

  var commitsTimer = null;
  function openCommits(open, immediate) {
    clearTimeout(commitsTimer);
    if (open) {
      if (S.commitsOpen) return;
      S.commitsOpen = true;
      if (!S.commits.length && !S.commitsDone) loadCommits();
      renderMenu();
      return;
    }
    var close = function () { if (S.commitsOpen) { S.commitsOpen = false; renderMenu(); } };
    if (immediate) close();
    else commitsTimer = setTimeout(close, 120);
  }

  function setMenu(open) {
    S.menuOpen = open;
    if (!open) S.commitsOpen = false;
    renderBar();
    renderMenu();
  }

  // ---------- data ----------
  function loadCounts() {
    call('counts', {}, function (data) {
      S.counts = data;
      renderBar();
      if (S.menuOpen) renderMenu();
    });
  }

  function loadCommits() {
    call('commits', { skip: S.commits.length, limit: PAGE }, function (data) {
      S.commits = S.commits.concat(data || []);
      if (!data || data.length < PAGE) S.commitsDone = true;
      if (S.menuOpen) renderMenu();
    });
  }

  function loadFiles(keepPane) {
    var seq = ++S.loadSeq;
    call('files', { filter: S.filter }, function (files) {
      if (seq !== S.loadSeq) return;
      var same = keepPane && JSON.stringify(files) === JSON.stringify(S.files);
      S.files = files || [];
      if (S.selected && !S.files.some(function (f) { return f.path === S.selected; })) S.selected = null;
      renderSide();
      if (!same) renderPane();
    });
  }

  function setFilter(f) {
    var changed = filterKey(f) !== filterKey(S.filter);
    S.filter = f;
    S.selected = null;
    setMenu(false);
    if (changed) {
      S.files = [];
      renderSide();
      renderPane();
      loadFiles(false);
    }
  }

  // ---------- sidebar ----------
  function splitPath(p) {
    var i = p.lastIndexOf('/');
    return i < 0 ? { dir: '', name: p } : { dir: p.slice(0, i), name: p.slice(i + 1) };
  }

  function renderSide() {
    var side = $('sideList');
    side.innerHTML = '';
    if (!S.files.length) return;
    var files = visibleFiles();
    if (!files.length) {
      side.appendChild(el('div', 'note', 'No matching files'));
      return;
    }
    var a = 0, r = 0;
    files.forEach(function (f) { a += f.added; r += f.removed; });
    var all = el('button', 'row all' + (S.selected == null ? ' sel' : ''));
    all.type = 'button';
    all.setAttribute('data-all', '1');
    var total = files.length === S.files.length ? '' + files.length : files.length + ' of ' + S.files.length;
    all.innerHTML = '<span class="name">All files</span><span class="badge">' + total + '</span>' + statHTML(a, r);
    all.addEventListener('click', function () { select(null); });
    side.appendChild(all);
    side.appendChild(el('div', 'sep'));
    files.forEach(function (f) {
      var parts = splitPath(f.path);
      var b = el('button', 'row' + (S.selected === f.path ? ' sel' : ''));
      b.type = 'button';
      b.setAttribute('data-path', f.path);
      b.title = f.path;
      b.innerHTML = '<span class="st ' + f.status + '">' + f.status + '</span>'
        + '<span class="name">' + esc(parts.name) + (parts.dir ? '<span class="dir">' + esc(parts.dir) + '</span>' : '') + '</span>'
        + statHTML(f.added, f.removed);
      b.addEventListener('click', function () { select(f.path); });
      side.appendChild(b);
    });
    var cur = side.querySelector('.row.sel');
    if (cur && cur.scrollIntoView) cur.scrollIntoView({ block: 'nearest' });
  }

  function setQuery(value) {
    var before = visibleFiles().map(function (f) { return f.path; }).join('\0');
    S.query = value;
    var after = visibleFiles().map(function (f) { return f.path; }).join('\0');
    if (S.selected && !visibleFiles().some(function (f) { return f.path === S.selected; })) S.selected = null;
    renderSide();
    if (before !== after || S.selected == null) renderPane();
  }

  /** Order used by the arrow keys: "All files" first, then each visible file. */
  function navigate(to) {
    var paths = [null].concat(visibleFiles().map(function (f) { return f.path; }));
    if (paths.length < 2) return;
    var i = Math.max(0, paths.indexOf(S.selected));
    var next;
    if (to === 'first') next = 1;
    else if (to === 'last') next = paths.length - 1;
    else next = Math.max(0, Math.min(paths.length - 1, i + to));
    select(paths[next]);
  }

  function focusFilter() {
    var q = $('fileFilter');
    q.focus();
    q.select();
  }

  function onKey(e) {
    var q = $('fileFilter');
    var inField = document.activeElement === q;
    // ⌘F (or "/" outside the field) jumps to the filter.
    if ((e.metaKey && !e.ctrlKey && !e.altKey && e.key.toLowerCase() === 'f')
        || (!inField && !e.metaKey && !e.ctrlKey && !e.altKey && e.key === '/')) {
      e.preventDefault();
      if (S.menuOpen) setMenu(false);
      focusFilter();
      return;
    }
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === 'Escape') {
      if (S.menuOpen) { setMenu(false); e.preventDefault(); return; }
      if (inField) { q.blur(); e.preventDefault(); }
      return;
    }
    if (S.menuOpen) return;
    // Arrows work from the filter field too (caret keys stay Left/Right).
    if (e.key === 'ArrowDown') { e.preventDefault(); navigate(1); return; }
    if (e.key === 'ArrowUp') { e.preventDefault(); navigate(-1); return; }
    if (inField) return;
    if (e.key === 'j') { navigate(1); e.preventDefault(); }
    else if (e.key === 'k') { navigate(-1); e.preventDefault(); }
    else if (e.key === 'Home') { navigate('first'); e.preventDefault(); }
    else if (e.key === 'End') { navigate('last'); e.preventDefault(); }
  }

  function select(path) {
    if (S.selected === path) return;
    S.selected = path;
    renderSide();
    renderPane();
  }

  // ---------- pane ----------
  // Monaco diffs are heavy: build them one at a time, yielding between each so hover/scroll stay live.
  var queue = [];
  var pumping = false;
  function enqueue(slot) {
    slot.requested = true;
    queue.push(slot);
    pump();
  }
  function pump() {
    if (pumping) return;
    var slot = queue.shift();
    if (!slot) return;
    if (slot.dead) { pump(); return; }
    pumping = true;
    var finished = false;
    var finish = function () {
      if (finished) return;
      finished = true;
      pumping = false;
      setTimeout(pump, 30);
    };
    setTimeout(finish, 6000); // never let one stuck mount stall the queue
    mount(slot, finish);
  }

  function disposeSlots() {
    queue = [];
    if (S.far) { S.far.disconnect(); S.far = null; }
    if (S.observer) { S.observer.disconnect(); S.observer = null; }
    S.slots.forEach(function (s) { if (s.handle) s.handle.dispose(); s.dead = true; });
    S.slots = [];
  }

  function singleMaxHeight() {
    return Math.max(160, $('pane').clientHeight - 24 - 36);
  }

  function renderPane() {
    disposeSlots();
    var pane = $('pane');
    pane.innerHTML = '';
    pane.scrollTop = 0;
    var files = visibleFiles();
    if (!files.length) {
      pane.appendChild(el('div', 'empty', S.files.length ? 'No matching files' : 'No changes'));
      return;
    }
    var single = S.selected != null;
    var list = single ? files.filter(function (f) { return f.path === S.selected; }) : files;
    if (!single) {
      S.observer = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (!e.isIntersecting) return;
          var slot = e.target.__slot;
          if (slot && !slot.requested) enqueue(slot);
          if (S.observer) S.observer.unobserve(e.target);
        });
      }, { root: pane, rootMargin: '250px 0px' });
      // Far offscreen diffs are torn down (height kept) so only a handful of Monaco editors stay live.
      S.far = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          var slot = e.target.__slot;
          if (e.isIntersecting || !slot || !slot.handle) return;
          var h = e.target.offsetHeight;
          slot.handle.dispose();
          slot.handle = null;
          slot.requested = false;
          e.target.innerHTML = '';
          e.target.style.height = h + 'px';
          var ph = el('div', 'ph');
          ph.textContent = slot.file.path;
          e.target.appendChild(ph);
          if (S.observer) S.observer.observe(e.target);
        });
      }, { root: pane, rootMargin: '1800px 0px' });
    }
    list.forEach(function (f) {
      var node = el('div', 'slot');
      node.setAttribute('data-path', f.path);
      var ph = el('div', 'ph');
      ph.textContent = f.path;
      node.appendChild(ph);
      pane.appendChild(node);
      var slot = { file: f, node: node, handle: null, requested: false, dead: false, single: single };
      node.__slot = slot;
      S.slots.push(slot);
      if (single) enqueue(slot);
      else { S.observer.observe(node); S.far.observe(node); }
    });
  }

  function mount(slot, done) {
    slot.requested = true;
    var key = filterKey(S.filter);
    call('content', { filter: S.filter, file: slot.file }, function (data) {
      if (slot.dead || key !== filterKey(S.filter) || !data) { done(); return; }
      var opts = {
        path: slot.file.path,
        original: data.original,
        modified: data.modified,
        added: slot.file.added,
        removed: slot.file.removed,
        mode: S.mode,
        hideModes: true,
        fullPath: true,
        maxHeight: slot.single ? singleMaxHeight() : 520,
        tooLarge: !!data.tooLarge
      };
      if (data.binary) opts.message = 'Binary file not shown';
      slot.node.style.height = '';
      slot.handle = window.CodeView.createDiff(slot.node, opts);
      slot.handle.ready.then(done);
    });
  }

  function setMode(mode) {
    S.mode = mode;
    S.slots.forEach(function (s) { if (s.handle) s.handle.setMode(mode); });
    renderBar();
  }

  // ---------- sidebar resize ----------
  var SIDE_MIN = 180, SIDE_MAX = 640, SIDE_DEFAULT = 270, PANE_MIN = 320;

  function clampSide(w) {
    var max = Math.max(SIDE_MIN, Math.min(SIDE_MAX, window.innerWidth - PANE_MIN));
    return Math.max(SIDE_MIN, Math.min(max, Math.round(w)));
  }

  function applySideWidth(w) {
    S.sideWidth = clampSide(w);
    $('side').style.width = S.sideWidth + 'px';
  }

  function initResizer() {
    var bar = $('resizer');
    var dragging = false;
    bar.addEventListener('pointerdown', function (e) {
      dragging = true;
      try { bar.setPointerCapture(e.pointerId); } catch (x) { /* synthetic pointer */ }
      bar.classList.add('drag');
      document.body.classList.add('resizing');
      e.preventDefault();
    });
    bar.addEventListener('pointermove', function (e) {
      if (dragging) applySideWidth(e.clientX);
    });
    function end(e) {
      if (!dragging) return;
      dragging = false;
      try { bar.releasePointerCapture(e.pointerId); } catch (x) { /* already released */ }
      bar.classList.remove('drag');
      document.body.classList.remove('resizing');
      post({ op: 'sidebarWidth', width: S.sideWidth });
    }
    bar.addEventListener('pointerup', end);
    bar.addEventListener('pointercancel', end);
    bar.addEventListener('dblclick', function () {
      applySideWidth(SIDE_DEFAULT);
      post({ op: 'sidebarWidth', width: S.sideWidth });
    });
  }

  // ---------- boot ----------
  function init() {
    initResizer();
    try { S.mode = window.CodeView.getSavedMode(); } catch (e) { /* default */ }
    $('filterBtn').addEventListener('click', function (e) {
      e.stopPropagation();
      setMenu(!S.menuOpen);
      if (S.menuOpen) loadCounts();
    });
    $('menu').addEventListener('click', function (e) { e.stopPropagation(); });
    document.addEventListener('click', function () { if (S.menuOpen) setMenu(false); });
    document.addEventListener('keydown', onKey);
    document.querySelectorAll('#modeSeg button').forEach(function (b) {
      b.addEventListener('click', function () { setMode(b.getAttribute('data-mode')); });
    });
    var q = $('fileFilter');
    q.addEventListener('input', function () { setQuery(q.value); });
    q.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && q.value) { q.value = ''; setQuery(''); e.preventDefault(); e.stopPropagation(); }
      if (e.key === 'Enter') { q.blur(); }
    });
    window.addEventListener('resize', function () {
      if (S.sideWidth) applySideWidth(S.sideWidth);
      S.slots.forEach(function (s) {
        if (s.handle && s.single && s.handle.setMaxHeight) s.handle.setMaxHeight(singleMaxHeight());
      });
    });
    renderBar();
  }

  window.Changes = {
    state: S,
    setContext: function (ctx) {
      S.context = ctx || S.context;
      if (ctx && ctx.sidebarWidth) applySideWidth(ctx.sidebarWidth);
      renderBar();
      loadCounts();
      loadFiles(false);
    },
    refresh: function () {
      loadCounts();
      loadFiles(true);
    },
    receive: function (id, data) {
      var cb = pending[id];
      delete pending[id];
      if (cb) cb(data);
    },
    setFilter: setFilter,
    setQuery: setQuery,
    select: select,
    setMode: setMode
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
