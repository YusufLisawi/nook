(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const ui = {
    add: $('add'), input: $('new'), list: $('list'), empty: $('empty'), count: $('count'), clear: $('clear'),
    timer: document.querySelector('.timer'), timerText: $('timer-text'), timerStop: $('timer-stop')
  };
  let todos = [];
  let visible = false;

  // ---- To-dos -------------------------------------------------------------

  const save = () => nook.storage.set('todos', todos);

  function render() {
    // Open items first (newest on top), done items after.
    const sorted = [...todos].sort((a, b) => Number(a.done) - Number(b.done) || b.created - a.created);
    ui.list.replaceChildren(...sorted.map((t) => {
      const li = document.createElement('li');
      li.className = `item${t.done ? ' done' : ''}`;
      li.innerHTML = '<button class="box" type="button"><svg class="icon"><use href="#i-check"/></svg></button><span class="text"></span><button class="del" type="button" title="Delete"><svg class="icon"><use href="#i-x"/></svg></button>';
      const text = li.querySelector('.text');
      text.textContent = t.text;
      li.querySelector('.box').title = t.done ? 'Mark as not done' : 'Mark as done';
      li.querySelector('.box').onclick = () => update(t.id, { done: !t.done });
      li.querySelector('.del').onclick = () => { todos = todos.filter((x) => x.id !== t.id); save(); render(); };
      // Double-click to edit in place; Enter or blur saves, Escape cancels.
      text.ondblclick = () => {
        text.contentEditable = 'plaintext-only';
        text.focus();
        getSelection().selectAllChildren(text);
      };
      text.onkeydown = (e) => {
        if (e.key === 'Enter') { e.preventDefault(); text.blur(); }
        if (e.key === 'Escape') { text.textContent = t.text; text.blur(); }
      };
      text.onblur = () => {
        if (text.contentEditable !== 'plaintext-only') return;
        text.contentEditable = 'false';
        const value = text.textContent.trim();
        if (value && value !== t.text) update(t.id, { text: value });
        else text.textContent = t.text;
      };
      return li;
    }));
    const open = todos.filter((t) => !t.done).length;
    const done = todos.length - open;
    ui.empty.hidden = todos.length > 0;
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
    if (!text) return;
    todos.push({ id: crypto.randomUUID(), text, done: false, created: Date.now() });
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
    const s = await nook.system();
    setStat('cpu', s.cpu?.usage);
    setStat('mem', s.memory ? s.memory.used / s.memory.total : 0);
    setStat('disk', s.disk ? s.disk.used / s.disk.total : 0);
  }

  // ---- Timer --------------------------------------------------------------

  function showTimer(t) {
    const running = t && t.mode === 'timer' && t.running;
    ui.timer.classList.toggle('running', !!running);
    ui.timerText.textContent = running ? t.text : 'Focus timer';
    ui.timerStop.hidden = !running;
  }

  document.querySelectorAll('.chips button').forEach((b) => {
    b.onclick = async () => showTimer(await nook.timer.start(Number(b.dataset.min)));
  });
  ui.timerStop.onclick = async () => showTimer(await nook.timer.stop());

  // Poll only while this tab is on screen.
  async function tick() {
    if (!visible) return;
    await Promise.all([tickStats(), nook.timer.state().then(showTimer)]).catch(() => {});
  }
  nook.on('open', (tab) => { visible = tab === nook.plugin.id; tick(); });
  nook.on('show', (tab) => { visible = tab === nook.plugin.id; tick(); });
  nook.on('close', () => { visible = false; });
  setInterval(tick, 1000);

  nook.storage.get('todos').then((saved) => {
    todos = Array.isArray(saved) ? saved : [];
    render();
  });
  visible = true;
  tick();
})();
