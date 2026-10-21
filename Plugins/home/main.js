(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const ui = {
    add: $('add'), input: $('new'), list: $('list'), empty: $('empty'), count: $('count'), clear: $('clear'),
    timer: document.querySelector('.timer'), timerText: $('timer-text'), timerStop: $('timer-stop')
  };
  let todos = [];
  let visible = false;
  const capabilities = { monitor: !nook.features, timers: !nook.features };
  function applyFeatures(rows) {
    for (const id of ['monitor', 'timers']) capabilities[id] = rows.find(row => row.id === id)?.enabled !== false;
    applySettings(settings);
  }
  if (nook.features) {
    nook.on('features', applyFeatures);
    nook.features.list().then(applyFeatures).catch(() => {});
  }
  let loaded = false;
  let loading = true;
  const errors = new Map();

  function showError(key, error) {
    if (error) errors.set(key, String(error.message || error)); else errors.delete(key);
    $('error').hidden = errors.size === 0;
    $('error-text').textContent = [...errors.values()].join(' ');
    $('retry').hidden = loaded || loading;
  }

  // ---- To-dos -------------------------------------------------------------

  const save = () => nook.storage.set('todos', todos).then(() => showError('save', null))
    .catch(error => showError('save', `Couldn't save to-dos: ${error.message || error}`));

  // Manual order: open items follow `order` (drag or ⌥↑/⌥↓), new ones go on top; done items sink below.
  const rank = (t) => (typeof t.order === 'number' ? t.order : -t.created);
  const byOrder = (a, b) => Number(a.done) - Number(b.done) || rank(a) - rank(b);
  function move(id, toIndex) {
    const open = todos.filter((t) => !t.done).sort(byOrder);
    const from = open.findIndex((t) => t.id === id);
    if (from < 0) return;
    const [item] = open.splice(from, 1);
    open.splice(Math.max(0, Math.min(open.length, toIndex)), 0, item);
    const order = new Map(open.map((t, i) => [t.id, i]));
    todos = todos.map((t) => (order.has(t.id) ? { ...t, order: order.get(t.id) } : t));
    save();
    render();
    [...ui.list.children].find((row) => row.dataset.nkItem === id)?.focus();
  }
  let dragging = null;

  function render() {
    const sorted = [...todos].filter((t) => !(settings?.hideDone && t.done)).sort(byOrder);
    ui.list.replaceChildren(...sorted.map((t) => {
      const li = document.createElement('li');
      li.className = `item${t.done ? ' done' : ''}`;
      li.dataset.nkItem = t.id;
      li.setAttribute('aria-label', `${t.text}, ${t.done ? 'done' : 'to do'}`);
      li.onclick = (event) => { if (event.target === li) li.querySelector('.box').click(); };
      li.addEventListener('nk:alt', () => li.querySelector('.text').ondblclick());
      if (!t.done) {
        // Pointer-based drag (not HTML5 drag-and-drop: that goes through the system drag pasteboard, which the notch
        // treats as files dropped on it). Press, move 4px, and the row follows; release to drop.
        li.onpointerdown = (e) => {
          if (e.button !== 0 || e.target.closest('button,[contenteditable="plaintext-only"]')) return;
          const startY = e.clientY;
          let started = false;
          const rows = () => [...ui.list.querySelectorAll('.item:not(.done)')];
          const onMove = (m) => {
            if (!started && Math.abs(m.clientY - startY) < 4) return;
            if (!started) { started = true; dragging = t.id; li.classList.add('dragging'); li.setPointerCapture(e.pointerId); }
            li.style.transform = `translateY(${m.clientY - startY}px)`;
            rows().forEach((r) => r.classList.remove('drop-before', 'drop-after'));
            const over = rows().find((r) => r !== li && m.clientY >= r.getBoundingClientRect().top && m.clientY <= r.getBoundingClientRect().bottom);
            if (over) over.classList.add(m.clientY > over.getBoundingClientRect().top + over.offsetHeight / 2 ? 'drop-after' : 'drop-before');
          };
          const onUp = () => {
            li.removeEventListener('pointermove', onMove); li.removeEventListener('pointerup', onUp); li.removeEventListener('pointercancel', onUp);
            if (!started) return;
            const target = rows().find((r) => r.classList.contains('drop-before') || r.classList.contains('drop-after'));
            li.style.transform = ''; li.classList.remove('dragging'); dragging = null;
            if (!target) { render(); return; }
            const open = todos.filter((x) => !x.done).sort(byOrder).map((x) => x.id).filter((x) => x !== t.id);
            move(t.id, open.indexOf(target.dataset.nkItem) + (target.classList.contains('drop-after') ? 1 : 0));
          };
          li.addEventListener('pointermove', onMove); li.addEventListener('pointerup', onUp); li.addEventListener('pointercancel', onUp);
        };
        li.onclick = (event) => { if (dragging) return; if (event.target === li) li.querySelector('.box').click(); };
        li.addEventListener('keydown', (e) => {
          if (!e.altKey || (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') || e.target !== li) return;
          e.preventDefault(); e.stopPropagation();
          const open = todos.filter((x) => !x.done).sort(byOrder);
          move(t.id, open.findIndex((x) => x.id === t.id) + (e.key === 'ArrowUp' ? -1 : 1));
        });
      }
      li.innerHTML = '<button class="box" type="button"><svg class="icon"><use href="#i-check"/></svg></button><span class="text"></span><button class="del" type="button" title="Delete"><svg class="icon"><use href="#i-x"/></svg></button>';
      const text = li.querySelector('.text');
      text.textContent = t.text;
      li.querySelector('.box').title = t.done ? 'Mark as not done' : 'Mark as done';
      li.querySelector('.box').onclick = () => update(t.id, { done: !t.done });
      li.querySelector('.del').onclick = () => { todos = todos.filter((x) => x.id !== t.id); save(); render(); };
      // Double-click to edit in place; Enter or blur saves, Escape cancels.
      text.ondblclick = () => {
        text.setAttribute('contenteditable', 'plaintext-only');
        text.tabIndex = -1;
        text.focus();
        getSelection().selectAllChildren(text);
      };
      text.onkeydown = (e) => {
        if (e.key === 'Enter') {
          e.preventDefault();
          text.blur();
          [...ui.list.children].find(row => row.dataset.nkItem === t.id)?.focus();
        }
        if (e.key === 'Escape') { text.textContent = t.text; text.blur(); }
      };
      text.onblur = () => {
        if (text.getAttribute('contenteditable') !== 'plaintext-only') return;
        text.setAttribute('contenteditable', 'false');
        const value = text.textContent.trim();
        if (value && value !== t.text) update(t.id, { text: value });
        else text.textContent = t.text;
      };
      return li;
    }));
    const open = todos.filter((t) => !t.done).length;
    const done = todos.length - open;
    ui.empty.hidden = sorted.length > 0;
    ui.empty.textContent = !loaded ? loading ? 'Loading to-dos…' : 'To-dos unavailable. Try loading again.' : settings.emptyText || 'Nothing to do.';
    ui.input.disabled = !loaded;
    ui.count.textContent = todos.length ? `${open} left` : '';
    ui.clear.hidden = done === 0;
  }

  function update(id, patch) {
    todos = todos.map((t) => (t.id === id ? { ...t, ...patch } : t));
    save();
    render();
  }

  ui.add.onsubmit = (e) => {
    e.preventDefault();
    const text = ui.input.value.trim();
    if (!text || !loaded) return;
    const top = Math.min(0, ...todos.filter((t) => !t.done).map(rank));
    todos.push({ id: crypto.randomUUID(), text, done: false, created: Date.now(), order: top - 1 });
    ui.input.value = '';
    save();
    render();
  };
  ui.clear.onclick = () => { todos = todos.filter((t) => !t.done); save(); render(); };

  // ---- Stats --------------------------------------------------------------

  function setStat(name, ratio) {
    const pct = Math.round(Math.max(0, Math.min(1, ratio || 0)) * 100);
    const bar = $(`${name}-bar`);
    bar.style.width = `${pct}%`;
    bar.className = pct >= 90 ? 'bad' : pct >= 70 ? 'warn' : '';
    $(name).textContent = `${pct}%`;
  }

  async function tickStats() {
    if (!capabilities.monitor || !settings.showStats) return;
    const s = await nook.system();
    setStat('cpu', s.cpu?.usage);
    setStat('mem', s.memory ? s.memory.used / s.memory.total : 0);
    setStat('disk', s.disk ? s.disk.used / s.disk.total : 0);
  }

  // ---- Timer --------------------------------------------------------------

  function showTimer(t) {
    const running = t && (t.mode === 'timer' || t.mode === 'pomodoro') && t.running;
    ui.timer.classList.toggle('running', !!running);
    ui.timerText.textContent = running ? t.text : 'Focus timer';
    ui.timerStop.hidden = !running;
  }

  async function timerAction(fn, ...args) {
    try { showTimer(await nook.timer[fn](...args)); showError('timer', null); }
    catch (error) { showError('timer', `Couldn't update timer: ${error.message || error}`); }
  }

  document.querySelectorAll('.chips button').forEach((b) => {
    b.onclick = () => timerAction('start', Number(b.dataset.min));
  });
  ui.timerStop.onclick = () => timerAction('stop');

  // Poll only while this tab is on screen.
  async function tick() {
    if (!visible) return;
    try { await Promise.all([tickStats(), capabilities.timers && settings.showTimer ? nook.timer.state().then(showTimer) : Promise.resolve()]); showError('live', null); }
    catch (error) { showError('live', `Couldn't refresh status: ${error.message || error}`); }
  }
let pollTimer = null;
function setPolling(on) {
  clearInterval(pollTimer); pollTimer = null;
  visible = on;
  if (on && (capabilities.monitor && settings?.showStats || capabilities.timers && settings?.showTimer)) { void tick(); pollTimer = setInterval(tick, 1000); }
}
nook.on('open', tab => setPolling(tab === nook.plugin.id));
nook.on('show', tab => setPolling(tab === nook.plugin.id));
nook.on('close', () => setPolling(false));
nook.on('visibility', setPolling);
setPolling(true);

  // ---- Settings (declared in plugin.json, edited from the notch's sliders button) ----

  var settings = { showStats: true, showTimer: true, timerPresets: '15, 30, 60', hideDone: false, emptyText: 'Nothing to do. Enjoy it.' };

  function applySettings(next) {
    settings = { ...settings, ...(next || {}) };
    const statsOn = settings.showStats && capabilities.monitor, timerOn = settings.showTimer && capabilities.timers;
    document.querySelector('.stats').hidden = !statsOn;
    ui.timer.hidden = !timerOn;
    document.querySelector('.side').hidden = !statsOn && !timerOn;
    document.querySelector('.app').classList.toggle('solo', !statsOn && !timerOn);
    $('empty').textContent = settings.emptyText || 'Nothing to do.';
    const minutes = String(settings.timerPresets).split(/[,\s]+/).map(Number).filter((n) => n > 0 && n <= 600).slice(0, 4);
    const chips = document.querySelector('.chips');
    chips.replaceChildren(...(minutes.length ? minutes : [15, 30, 60]).map((m) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.dataset.nkItem = String(m);
      b.textContent = m % 60 === 0 ? `${m / 60}h` : `${m}m`;
      b.onclick = () => timerAction('start', m);
      return b;
    }));
    render();
    setPolling(visible);
  }
  nook.on('settings', applySettings);
  nook.settings.get().then(applySettings).catch(error => { applySettings(); showError('settings', error); });

  async function loadTodos() {
    loading = true;
    render();
    try {
      const saved = await nook.storage.get('todos');
      todos = Array.isArray(saved) ? saved : [];
      loaded = true;
      showError('load', null);
    } catch (error) { showError('load', `Couldn't load to-dos: ${error.message || error}`); }
    loading = false;
    $('retry').hidden = loaded;
    render();
  }
  $('retry').onclick = loadTodos;
  void loadTodos();
  visible = true;
  tick();
})();
