(function () {
  const HANDS = [
    {id: 'lavender', name: 'Lavender toy', src: 'assets/hands/lavender.png', w: 257, h: 380, tip: [95.3, 12.0], wrist: [127.8, 368.6], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#8754f2'},
    {id: 'glove', name: 'Cursor glove', src: 'assets/hands/glove.png', w: 254, h: 380, tip: [93.9, 12.3], wrist: [128.3, 368.3], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#8754f2'},
    {id: 'coral', name: 'Coral vinyl', src: 'assets/hands/coral.png', w: 317, h: 380, tip: [100.6, 11.4], wrist: [153.9, 369.2], stick: ['#ffffff', '#e7e3df', '#c9c3bd'], ink: '#ff2a1f'},
    {id: 'plush', name: 'Plush', src: 'assets/hands/plush.png', w: 303, h: 380, tip: [106.4, 11.0], wrist: [142.3, 369.6], stick: ['#f1dcb6', '#d6b383', '#a9824f'], ink: '#2f86f0'},
    {id: 'robot', name: 'Robot', src: 'assets/hands/robot.png', w: 345, h: 380, tip: [116.1, 11.8], wrist: [181.3, 368.8], stick: ['#e2e5e8', '#b6bbc1', '#7d838a'], ink: '#16a87a'},
    {id: 'pink', name: 'Bubblegum', src: 'assets/hands/pink.png', w: 245, h: 380, tip: [87.8, 12.4], wrist: [122.5, 368.2], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#ee4f98'},
    {id: 'blue', name: 'Sky', src: 'assets/hands/blue.png', w: 251, h: 380, tip: [90.4, 12.4], wrist: [125.7, 368.2], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#2f86f0'},
    {id: 'mint', name: 'Mint', src: 'assets/hands/mint.png', w: 255, h: 380, tip: [94.5, 12.3], wrist: [128.6, 368.3], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#16a87a'},
    {id: 'lemon', name: 'Lemon', src: 'assets/hands/lemon.png', w: 251, h: 380, tip: [92.1, 12.3], wrist: [125.5, 368.3], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#f2b705'},
    {id: 'black', name: 'Midnight', src: 'assets/hands/black.png', w: 244, h: 380, tip: [81.1, 12.3], wrist: [121.9, 368.3], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#1d1d21'},
    {id: 'chrome', name: 'Chrome', src: 'assets/hands/chrome.png', w: 251, h: 380, tip: [87.2, 12.3], wrist: [124.1, 368.4], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#6b7380'},
    {id: 'holo', name: 'Holo', src: 'assets/hands/holo.png', w: 239, h: 380, tip: [85.5, 12.6], wrist: [116.4, 368.1], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#8754f2'},
    {id: 'fuzzy', name: 'Fuzzy', src: 'assets/hands/fuzzy.png', w: 255, h: 380, tip: [93.9, 12.3], wrist: [128.7, 368.4], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#8754f2'},
    {id: 'wood', name: 'Wood', src: 'assets/hands/wood.png', w: 250, h: 380, tip: [92.7, 12.2], wrist: [127.2, 368.4], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#9a5e2c'},
    {id: 'marble', name: 'Marble', src: 'assets/hands/marble.png', w: 253, h: 380, tip: [89.8, 12.4], wrist: [127.4, 368.2], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#6b7380'},
    {id: 'terrazzo', name: 'Terrazzo', src: 'assets/hands/terrazzo.png', w: 254, h: 380, tip: [89.1, 12.5], wrist: [123.4, 368.1], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#f0561d'},
    {id: 'glass', name: 'Glass', src: 'assets/hands/glass.png', w: 251, h: 380, tip: [88.3, 12.8], wrist: [128.6, 367.9], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#1597e5'},
    {id: 'jelly', name: 'Jelly', src: 'assets/hands/jelly.png', w: 247, h: 380, tip: [88.4, 12.8], wrist: [121.1, 367.9], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#a33fe6'},
    {id: 'pastel', name: 'Pastel', src: 'assets/hands/pastel.png', w: 252, h: 380, tip: [91.9, 12.3], wrist: [127.9, 368.3], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#ee4f98'},
    {id: 'pixel', name: 'Pixel', src: 'assets/hands/pixel.png', w: 261, h: 380, tip: [105.7, 11.6], wrist: [131.0, 369.0], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#1d1d21'},
    {id: 'lowpoly', name: 'Low poly', src: 'assets/hands/lowpoly.png', w: 251, h: 380, tip: [89.3, 12.3], wrist: [125.3, 368.3], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#8754f2'},
    {id: 'knit', name: 'Knit', src: 'assets/hands/knit.png', w: 243, h: 380, tip: [89.0, 12.6], wrist: [117.2, 368.1], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#8754f2'},
    {id: 'skeleton', name: 'Skeleton', src: 'assets/hands/skeleton.png', w: 241, h: 380, tip: [84.8, 13.6], wrist: [123.1, 367.1], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#9a5e2c'},
    {id: 'astro', name: 'Astronaut', src: 'assets/hands/astro.png', w: 241, h: 380, tip: [88.9, 12.0], wrist: [121.3, 368.7], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#2f86f0'},
    {id: 'space', name: 'Space', src: 'assets/hands/space.png', w: 246, h: 380, tip: [86.8, 12.3], wrist: [122.6, 368.4], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#ff2a1f'},
    {id: 'monster', name: 'Monster', src: 'assets/hands/monster.png', w: 255, h: 380, tip: [96.5, 11.5], wrist: [122.8, 369.1], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#3e9e2e'},
    {id: 'water', name: 'Water', src: 'assets/hands/water.png', w: 251, h: 380, tip: [89.3, 12.7], wrist: [128.5, 368.0], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#1597e5'},
    {id: 'lava', name: 'Lava', src: 'assets/hands/lava.png', w: 249, h: 380, tip: [86.0, 12.7], wrist: [122.7, 368.0], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#f0561d'},
    {id: 'grass', name: 'Grass', src: 'assets/hands/grass.png', w: 247, h: 380, tip: [88.9, 11.9], wrist: [123.0, 368.7], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#3e9e2e'},
    {id: 'cactus', name: 'Cactus', src: 'assets/hands/cactus.png', w: 225, h: 380, tip: [89.4, 12.6], wrist: [119.6, 368.0], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#3e9e2e'},
    {id: 'choco', name: 'Chocolate', src: 'assets/hands/choco.png', w: 243, h: 380, tip: [86.7, 12.4], wrist: [119.7, 368.2], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#9a5e2c'},
    {id: 'cloud', name: 'Cloud', src: 'assets/hands/cloud.png', w: 255, h: 380, tip: [90.6, 12.3], wrist: [127.3, 368.3], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#2f86f0'},
    {id: 'mech', name: 'Mech', src: 'assets/hands/mech.png', w: 260, h: 380, tip: [70.2, 5.3], wrist: [140.1, 372.1], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#f0561d'},
    {id: 'neon', name: 'Neon', src: 'assets/hands/neon.png', w: 249, h: 380, tip: [79.9, 5.3], wrist: [129.8, 372.1], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#e0309a'},
    {id: 'leaf', name: 'Leaf', src: 'assets/hands/leaf.png', w: 242, h: 380, tip: [66.3, 5.3], wrist: [129.0, 372.1], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#3e9e2e'},
    {id: 'cookie', name: 'Gingerbread', src: 'assets/hands/cookie.png', w: 249, h: 380, tip: [70.6, 5.3], wrist: [128.3, 372.1], stick: ['#3a3a3e', '#121214', '#000000'], ink: '#9a5e2c'},
  ];
  const PURPLE = '#8754f2';
  const RED = '#ff2a1f';
  const FADE_AFTER = 3000;
  const FADE_FOR = 600;

  const css = `
  .th-canvas { position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; z-index: 5; }
  .th-live { cursor: none; user-select: none; -webkit-user-select: none; touch-action: pan-y; }
  .th-live * { cursor: none !important; }
  .th-toolbar { position: absolute; left: 50%; bottom: 14px; transform: translateX(-50%); z-index: 4;
    display: flex; align-items: center; gap: 4px; padding: 6px 8px; border-radius: 16px;
    background: rgba(40, 40, 44, 0.86); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.22); }
  .th-toolbar button { all: unset; box-sizing: border-box; width: 38px; height: 38px; border-radius: 10px;
    display: grid; place-items: center; transition: background .15s ease; }
  .th-toolbar button:hover, .th-toolbar button:focus-visible { background: rgba(255, 255, 255, 0.1); }
  .th-toolbar button[aria-pressed="true"] { background: rgba(255, 255, 255, 0.2); }
  .th-toolbar img { width: 30px; height: 30px; object-fit: contain; pointer-events: none; }
  .th-toolbar .th-sep { width: 1px; height: 22px; background: rgba(255, 255, 255, 0.18); margin: 0 4px; }
  .th-laser-dot { width: 11px; height: 11px; border-radius: 50%; background: ${RED};
    box-shadow: 0 0 0 3px rgba(255, 42, 31, .25), 0 0 12px 4px rgba(255, 42, 31, .45); position: relative; }
  .th-laser-dot::after { content: ""; position: absolute; inset: 3px; border-radius: 50%; background: #ffdcd5; }
  .th-toolbar svg { width: 18px; height: 18px; fill: rgba(255, 255, 255, 0.85); }
  @media (max-width: 520px) { .th-toolbar button { width: 32px; height: 32px; } .th-toolbar img { width: 25px; height: 25px; } }
  `;

  function injectStyle() {
    if (document.getElementById('th-style')) {
      return;
    }
    const s = document.createElement('style');
    s.id = 'th-style';
    s.textContent = css;
    document.head.appendChild(s);
  }

  const SPEAKER_ON = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9h4l5-4v14l-5-4H4z"/><path d="M16.5 8.5a5 5 0 0 1 0 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" style="stroke:rgba(255,255,255,.85)"/><path d="M19 6a8.5 8.5 0 0 1 0 12" fill="none" stroke-width="2" stroke-linecap="round" style="stroke:rgba(255,255,255,.85)"/></svg>';
  const SPEAKER_OFF = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9h4l5-4v14l-5-4H4z"/><path d="M17 9l5 6M22 9l-5 6" fill="none" stroke-width="2" stroke-linecap="round" style="stroke:rgba(255,255,255,.85)"/></svg>';

  function mount(stage, options) {
    const opts = Object.assign({ base: '', sound: 'assets/tap.wav', toolbar: true, autoplay: true, start: 'lavender' }, options || {});
    injectStyle();
    if (getComputedStyle(stage).position === 'static') {
      stage.style.position = 'relative';
    }
    const canvas = document.createElement('canvas');
    canvas.className = 'th-canvas';
    stage.appendChild(canvas);
    const ctx = canvas.getContext('2d');

    const images = {};
    function image(id) {
      if (!images[id]) {
        const hand = HANDS.find(h => h.id === id);
        const img = new Image();
        img.onload = () => { dirty = true; };
        img.src = opts.base + hand.src;
        images[id] = img;
      }
      return images[id];
    }

    let style = HANDS.some(h => h.id === opts.start) ? opts.start : 'lavender';
    let dirty = true;
    let soundOn = { hands: true, laser: false };
    let W = 0, H = 0, dpr = 1;
    let cursor = null;
    let gripX = null;
    let held = false;
    let pressAmount = 0;
    let lastReal = 0;
    let downAt = null;
    let current = null;
    const strokes = [];
    let audio = null, buffer = null;
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    function resize() {
      const r = stage.getBoundingClientRect();
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = r.width; H = r.height;
      canvas.width = Math.round(W * dpr);
      canvas.height = Math.round(H * dpr);
    }
    resize();
    if (window.ResizeObserver) {
      new ResizeObserver(resize).observe(stage);
    }

    const soundBytes = fetch(opts.base + opts.sound).then(r => r.arrayBuffer()).catch(() => null);
    let pendingTap = false;
    function ensureAudio() {
      if (audio) {
        if (audio.state === 'suspended') {
          audio.resume();
        }
        return;
      }
      try {
        audio = new (window.AudioContext || window.webkitAudioContext)();
        soundBytes.then(b => (b ? audio.decodeAudioData(b.slice(0)) : null)).then(d => {
          buffer = d;
          if (pendingTap) {
            pendingTap = false;
            playBuffer();
          }
        }).catch(() => {});
      } catch (e) {}
    }
    function thock() {
      const on = style === 'laser' ? soundOn.laser : soundOn.hands;
      if (!on || !audio) {
        return;
      }
      if (!buffer) {
        pendingTap = true;
        return;
      }
      playBuffer();
    }
    function playBuffer() {
      if (!buffer) {
        return;
      }
      const src = audio.createBufferSource();
      src.buffer = buffer;
      src.connect(audio.destination);
      src.start();
    }

    let toolbar = null, soundBtn = null;
    if (opts.toolbar) {
      toolbar = document.createElement('div');
      toolbar.className = 'th-toolbar';
      const ids = HANDS.map(h => h.id).concat(['laser']);
      ids.forEach(id => {
        const b = document.createElement('button');
        b.type = 'button';
        b.dataset.style = id;
        const hand = HANDS.find(h => h.id === id);
        b.setAttribute('aria-label', hand ? hand.name : 'Laser dot');
        b.title = hand ? hand.name : 'Laser dot';
        b.innerHTML = hand ? `<img src="${opts.base + hand.src}" alt="">` : '<span class="th-laser-dot"></span>';
        b.addEventListener('click', () => setStyle(id));
        toolbar.appendChild(b);
      });
      const sep = document.createElement('span');
      sep.className = 'th-sep';
      toolbar.appendChild(sep);
      soundBtn = document.createElement('button');
      soundBtn.type = 'button';
      soundBtn.addEventListener('click', () => {
        ensureAudio();
        if (style === 'laser') {
          soundOn.laser = !soundOn.laser;
        } else {
          soundOn.hands = !soundOn.hands;
        }
        syncToolbar();
      });
      toolbar.appendChild(soundBtn);
      stage.appendChild(toolbar);
    }
    function syncToolbar() {
      if (!toolbar) {
        return;
      }
      toolbar.querySelectorAll('button[data-style]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.style === style)));
      const on = style === 'laser' ? soundOn.laser : soundOn.hands;
      soundBtn.innerHTML = on ? SPEAKER_ON : SPEAKER_OFF;
      soundBtn.setAttribute('aria-label', on ? 'Mute the tap sound' : 'Turn the tap sound on');
      soundBtn.title = soundBtn.getAttribute('aria-label');
    }
    function setStyle(id) {
      style = id;
      syncToolbar();
      stage.dispatchEvent(new CustomEvent('th-style', { detail: id }));
    }
    syncToolbar();

    function local(e) {
      const r = stage.getBoundingClientRect();
      return { x: e.clientX - r.left, y: e.clientY - r.top };
    }
    const source = opts.global ? window : stage;
    const liveEl = opts.global ? document.documentElement : stage;
    const passSelector = opts.global ? 'a, button, input, select, textarea, label, [data-pass]' : '[data-pass]';
    let enabled = opts.active !== false;
    function onToolbar(e) {
      return (toolbar && toolbar.contains(e.target)) || Boolean(e.target.closest && e.target.closest(passSelector));
    }
    source.addEventListener('pointermove', e => {
      if (e.pointerType !== 'mouse' || !enabled) {
        return;
      }
      lastReal = performance.now();
      liveEl.classList.add('th-live');
      cursor = local(e);
      if (downAt && !onToolbar(e)) {
        extend(cursor);
      }
    });
    stage.addEventListener('pointerleave', e => {
      if (e.pointerType !== 'mouse') {
        return;
      }
      stage.classList.remove('th-live');
      release();
      lastReal = 0;
      if (opts.autoplay) {
        cursor = null;
      }
    });
    source.addEventListener('pointerdown', e => {
      if (e.pointerType !== 'mouse' || !enabled || onToolbar(e)) {
        return;
      }
      e.preventDefault();
      ensureAudio();
      lastReal = performance.now();
      cursor = local(e);
      press(cursor);
    });
    window.addEventListener('pointerup', e => {
      if (e.pointerType === 'mouse') {
        release();
      }
    });
    source.addEventListener('click', e => {
      if (enabled && !onToolbar(e) && liveEl.classList.contains('th-live')) {
        e.preventDefault();
      }
    }, true);

    function activate(e) {
      enabled = true;
      ensureAudio();
      lastReal = performance.now();
      cursor = e ? local(e) : cursor;
      gripX = null;
      liveEl.classList.add('th-live');
      dirty = true;
    }
    function deactivate() {
      enabled = false;
      release();
      cursor = null;
      strokes.length = 0;
      liveEl.classList.remove('th-live');
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
    }

    function press(p) {
      held = true;
      pressAmount = 1;
      downAt = { x: p.x, y: p.y };
      thock();
    }
    function extend(p) {
      if (!current) {
        if (Math.hypot(p.x - downAt.x, p.y - downAt.y) < 4) {
          return;
        }
        const hand = HANDS.find(h => h.id === style);
        current = { pts: [downAt], color: style === 'laser' ? RED : (opts.ink || (hand && hand.ink) || PURPLE), ended: 0 };
        strokes.push(current);
      }
      const last = current.pts[current.pts.length - 1];
      if (Math.hypot(p.x - last.x, p.y - last.y) >= 1.5) {
        current.pts.push({ x: p.x, y: p.y });
      }
    }
    function release() {
      held = false;
      downAt = null;
      if (current) {
        current.ended = performance.now();
        current = null;
      }
    }

    const demo = { t: 0, steps: [], i: 0, from: null };
    function targets() {
      const r = stage.getBoundingClientRect();
      return Array.from(stage.querySelectorAll('[data-target]')).map(el => {
        const b = el.getBoundingClientRect();
        return { x: b.left - r.left, y: b.top - r.top, w: b.width, h: b.height, kind: el.dataset.target };
      }).filter(t => t.w > 0);
    }
    function planDemo() {
      const ts = targets();
      const steps = [];
      const circle = ts.find(t => t.kind === 'circle');
      const tap = ts.find(t => t.kind === 'tap');
      const point = ts.find(t => t.kind === 'point');
      if (point) {
        steps.push({ to: { x: point.x + point.w * 0.5, y: point.y + point.h * 0.55 }, dur: 1100 }, { wait: 700 });
      }
      if (circle) {
        const cx = circle.x + circle.w / 2, cy = circle.y + circle.h / 2;
        const rx = circle.w / 2 + 14, ry = circle.h / 2 + 10;
        const a0 = -Math.PI * 0.85;
        steps.push({ to: { x: cx + rx * Math.cos(a0), y: cy + ry * Math.sin(a0) }, dur: 900 }, { down: true },
          { circle: { cx, cy, rx, ry, a0 }, dur: 1300 }, { up: true }, { wait: 900 });
      }
      if (tap) {
        steps.push({ to: { x: tap.x + tap.w * 0.5, y: tap.y + tap.h * 0.5 }, dur: 900 }, { down: true }, { wait: 140 }, { up: true }, { wait: 300 },
          { down: true }, { wait: 120 }, { up: true }, { wait: 1200 });
      }
      if (!steps.length) {
        steps.push({ to: { x: W * 0.45, y: H * 0.4 }, dur: 1200 }, { wait: 1500 });
      }
      demo.steps = steps;
      demo.i = 0;
      demo.t = 0;
      demo.from = cursor || { x: W * 0.7, y: H * 0.85 };
    }
    function demoActive(now) {
      return opts.autoplay && !reduce && (now - lastReal > 2500);
    }
    function stepDemo(dt) {
      if (!demo.steps.length) {
        planDemo();
      }
      const s = demo.steps[demo.i];
      demo.t += dt;
      const ease = t => t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
      let done = true;
      if (s.to) {
        const k = Math.min(1, demo.t / s.dur);
        const e = ease(k);
        cursor = { x: demo.from.x + (s.to.x - demo.from.x) * e, y: demo.from.y + (s.to.y - demo.from.y) * e };
        done = k >= 1;
      } else if (s.circle) {
        const k = Math.min(1, demo.t / s.dur);
        const a = s.circle.a0 + ease(k) * Math.PI * 2.08;
        cursor = { x: s.circle.cx + s.circle.rx * Math.cos(a), y: s.circle.cy + s.circle.ry * Math.sin(a) };
        extend(cursor);
        done = k >= 1;
      } else if (s.wait) {
        done = demo.t >= s.wait;
      } else if (s.down) {
        press(cursor);
      } else if (s.up) {
        release();
      }
      if (done) {
        demo.i += 1;
        demo.t = 0;
        demo.from = cursor;
        if (demo.i >= demo.steps.length) {
          planDemo();
        }
      }
    }

    function drawInk(now) {
      const width = Math.max(3, Math.min(6, H * 0.008));
      for (let i = strokes.length - 1; i >= 0; i--) {
        const s = strokes[i];
        let alpha = 1;
        if (s.ended) {
          const age = now - s.ended - FADE_AFTER;
          if (age > FADE_FOR) {
            strokes.splice(i, 1);
            continue;
          }
          alpha = age > 0 ? 1 - age / FADE_FOR : 1;
        }
        const p = s.pts;
        ctx.save();
        ctx.globalAlpha = alpha;
        ctx.strokeStyle = s.color;
        ctx.lineWidth = width;
        ctx.lineCap = 'round';
        ctx.lineJoin = 'round';
        ctx.beginPath();
        ctx.moveTo(p[0].x, p[0].y);
        for (let k = 1; k < p.length; k++) {
          const m = { x: (p[k - 1].x + p[k].x) / 2, y: (p[k - 1].y + p[k].y) / 2 };
          ctx.quadraticCurveTo(p[k - 1].x, p[k - 1].y, m.x, m.y);
        }
        if (p.length > 1) {
          ctx.lineTo(p[p.length - 1].x, p[p.length - 1].y);
        }
        ctx.stroke();
        ctx.restore();
      }
    }

    function drawLaser() {
      const r = Math.max(4, Math.min(7, H * 0.009)) * (1 + 0.2 * pressAmount);
      ctx.save();
      ctx.shadowColor = RED;
      ctx.shadowBlur = r * (2.4 + pressAmount);
      ctx.fillStyle = RED;
      ctx.beginPath();
      ctx.arc(cursor.x, cursor.y, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.shadowBlur = 0;
      ctx.fillStyle = '#ffdcd5';
      ctx.beginPath();
      ctx.arc(cursor.x, cursor.y, r * 0.45, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }

    function drawHand(dt) {
      const hand = HANDS.find(h => h.id === style);
      const img = image(style);
      if (!img.complete || !img.naturalWidth) {
        return;
      }
      const handH = (opts.handH || Math.max(64, Math.min(124, H * 0.19))) * (1 - 0.06 * pressAmount);
      const s = handH / hand.h;
      const targetX = Math.min(Math.max(cursor.x + 0.18 * W, W * 0.15), W * 1.05);
      gripX = gripX == null ? targetX : gripX + (targetX - gripX) * Math.min(1, dt * 0.0096);
      const grip = { x: gripX, y: H + Math.max(H * 0.35, W * (opts.depthW || 0)) };
      const aScr = Math.atan2(cursor.y - grip.y, cursor.x - grip.x);
      const aImg = Math.atan2(hand.tip[1] - hand.wrist[1], hand.tip[0] - hand.wrist[0]);
      const rot = aScr - aImg;
      const dx = (hand.wrist[0] - hand.tip[0]) * s, dy = (hand.wrist[1] - hand.tip[1]) * s;
      const wrist = { x: cursor.x + dx * Math.cos(rot) - dy * Math.sin(rot), y: cursor.y + dx * Math.sin(rot) + dy * Math.cos(rot) };

      const sw = Math.max(4, handH * 0.07);
      ctx.save();
      const nx = -(wrist.y - grip.y), ny = wrist.x - grip.x;
      const nl = Math.hypot(nx, ny) || 1;
      const mx = (wrist.x + grip.x) / 2, my = (wrist.y + grip.y) / 2;
      const g = ctx.createLinearGradient(mx - nx / nl * sw / 2, my - ny / nl * sw / 2, mx + nx / nl * sw / 2, my + ny / nl * sw / 2);
      g.addColorStop(0, hand.stick[2]);
      g.addColorStop(0.35, hand.stick[1]);
      g.addColorStop(0.55, hand.stick[0]);
      g.addColorStop(1, hand.stick[2]);
      ctx.strokeStyle = g;
      ctx.lineWidth = sw;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(grip.x, grip.y);
      ctx.lineTo(wrist.x, wrist.y);
      ctx.stroke();

      ctx.translate(cursor.x, cursor.y);
      ctx.rotate(rot);
      ctx.drawImage(img, -hand.tip[0] * s, -hand.tip[1] * s, hand.w * s, hand.h * s);
      ctx.restore();
      return Math.abs(targetX - gripX) > 0.3;
    }

    let visible = true;
    if (window.IntersectionObserver) {
      new IntersectionObserver(entries => { visible = entries[entries.length - 1].isIntersecting; }).observe(stage);
    }
    ['pointermove', 'pointerdown', 'pointerleave'].forEach(t => source.addEventListener(t, () => { dirty = true; }));
    stage.addEventListener('th-style', () => { dirty = true; });
    if (window.ResizeObserver) {
      new ResizeObserver(() => { dirty = true; }).observe(stage);
    }

    let last = performance.now();
    let lastFrame = 0;
    function tick(now) {
      const dt = Math.max(0, Math.min(64, now - last));
      last = now;
      if (!visible || document.hidden || !enabled) {
        return;
      }
      let moving = false;
      if (!held && pressAmount > 0.002) {
        pressAmount += (0 - pressAmount) * Math.min(1, dt * 0.022);
        moving = true;
      }
      if (demoActive(now)) {
        stepDemo(dt);
        moving = true;
      } else if (demo.steps.length) {
        if (held && !lastReal) {
          release();
        }
        demo.steps = [];
      }
      if (!moving && !dirty && !held && !strokes.length) {
        return;
      }
      dirty = false;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, W, H);
      drawInk(now);
      if (!cursor) {
        return;
      }
      if (style === 'laser') {
        drawLaser();
        return;
      }
      if (drawHand(dt)) {
        dirty = true;
      }
    }
    function frame(now) {
      lastFrame = performance.now();
      tick(now);
      requestAnimationFrame(frame);
    }
    if (reduce || !opts.autoplay) {
      const t = targets().find(x => x.kind === 'point');
      cursor = t ? { x: t.x + t.w * 0.5, y: t.y + t.h * 0.55 } : { x: W * 0.5, y: H * 0.45 };
    }
    requestAnimationFrame(frame);
    setInterval(() => {
      if (performance.now() - lastFrame > 250) {
        tick(performance.now());
      }
    }, 33);

    function preload() {
      HANDS.forEach(h => image(h.id));
    }

    return { setStyle, setInk: c => { opts.ink = c; }, activate, deactivate, preload, get active() { return enabled; }, get style() { return style; }, hands: HANDS };
  }

  window.AiHandDemo = { mount, hands: HANDS };
})();
