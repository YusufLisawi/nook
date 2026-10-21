// Mouse — smooth scrolling, scroll modifiers and button remapping. Engine: nook.mouse.* (an event tap in Nook).
const $ = (id) => document.getElementById(id);
let state = null;
let view = 'scroll';
let built = false;

const SMOOTH = [['off', 'Off'], ['low', 'Low'], ['regular', 'Regular'], ['high', 'High']];
const MODIFIERS = [['none', 'Nothing'], ['shift', '⇧ Shift'], ['option', '⌥ Option'], ['control', '⌃ Control'], ['command', '⌘ Command']];
const BUTTON_NAMES = { 2: 'Middle', 3: 'Back', 4: 'Forward' };
const buttonName = (n) => BUTTON_NAMES[n] || `Button ${Number(n) + 1}`;

function showError(message, action) {
  const el = $('error');
  el.hidden = !message;
  if (!message) return;
  el.replaceChildren(Object.assign(document.createElement('span'), { className: 'nk-fill', textContent: message }));
  if (action) {
    const b = Object.assign(document.createElement('button'), { className: 'nk-btn nk-danger', textContent: action.label });
    b.onclick = action.run;
    el.append(b);
  }
}

async function call(fn, ...args) {
  try {
    const next = await nook.mouse[fn](...args);
    if (next) { state = next; render(); }
  } catch (err) {
    showError(`Couldn't ${fn.replace(/([A-Z])/g, ' $1').toLowerCase()}: ${err.message || err}`);
  }
}

/** Slider drags fire a lot; send at most one write per 120 ms, always ending on the final value. */
const timers = {};
function setSoon(key, value) {
  state.config[key] = value;
  clearTimeout(timers[key]);
  timers[key] = setTimeout(() => call('set', { [key]: value }), 120);
}

// ---- Scroll form -------------------------------------------------------------

function field(label, control, extra = '') {
  const row = document.createElement('div');
  row.className = `field ${extra}`;
  const l = Object.assign(document.createElement('span'), { className: 'name', textContent: label });
  const input = control.matches('input,select,button') ? control : control.querySelector('input,select');
  input?.setAttribute('aria-label', label);
  row.append(l, control);
  return row;
}

function select(options, key) {
  const el = document.createElement('select');
  el.className = 'nk-input pick';
  for (const [value, text] of options) el.append(Object.assign(document.createElement('option'), { value, textContent: text }));
  el.onchange = () => call('set', { [key]: el.value });
  el.dataset.key = key;
  return el;
}

function slider(key, min, max, step, format) {
  const wrap = document.createElement('div');
  wrap.className = 'nk-row-flex nk-fill';
  const input = Object.assign(document.createElement('input'), { type: 'range', min, max, step, className: 'nk-fill' });
  const value = Object.assign(document.createElement('span'), { className: 'value' });
  input.dataset.key = key;
  input.oninput = () => { value.textContent = format(+input.value); setSoon(key, +input.value); };
  wrap.append(input, value);
  wrap.sync = (v) => { if (document.activeElement !== input) input.value = v; value.textContent = format(v); };
  return wrap;
}

function toggle(key) {
  const label = document.createElement('label');
  label.className = 'nk-switch';
  const input = document.createElement('input');
  input.type = 'checkbox';
  input.dataset.key = key;
  input.onchange = () => call('set', { [key]: input.checked });
  label.append(input, document.createElement('span'));
  return label;
}

function buildScroll() {
  const form = $('scroll');
  form.replaceChildren(); // the loading spinner
  const seg = document.createElement('div');
  seg.className = 'nk-seg nk-roving';
  seg.dataset.nkOrientation = 'horizontal';
  seg.setAttribute('aria-label', 'Smoothness');
  seg.dataset.key = 'smoothness';
  for (const [value, text] of SMOOTH) {
    const b = Object.assign(document.createElement('button'), { textContent: text });
    b.dataset.value = value;
    b.dataset.nkItem = value;
    b.onclick = () => call('set', { smoothness: value });
    seg.append(b);
  }
  form.append(
    field('Smoothness', seg),
    field('Reverse direction', toggle('reverse')),
    field('Filter wheel chatter', toggle('filterChatter')),
    field('Speed', slider('speed', 0.3, 3, 0.1, (v) => `${v.toFixed(1)}×`)),
    field('Acceleration', slider('acceleration', 0, 1, 0.05, (v) => `${Math.round(v * 100)}%`)),
  );
  const sub = Object.assign(document.createElement('div'), { className: 'sub', textContent: 'While scrolling, hold…' });
  form.append(
    sub,
    field('Sideways', select(MODIFIERS, 'horizontalModifier')),
    field('Slow (precise)', select(MODIFIERS, 'preciseModifier')),
    field('Fast', select(MODIFIERS, 'quickModifier')),
  );
  built = true;
}

function syncScroll() {
  const c = state.config;
  for (const b of $('scroll').querySelectorAll('[data-key=smoothness] button')) b.classList.toggle('nk-on', b.dataset.value === c.smoothness);
  for (const el of $('scroll').querySelectorAll('select[data-key]')) el.value = c[el.dataset.key];
  for (const el of $('scroll').querySelectorAll('input[type=checkbox][data-key]')) el.checked = !!c[el.dataset.key];
  for (const wrap of $('scroll').querySelectorAll('.nk-row-flex')) {
    const input = wrap.querySelector('input[type=range]');
    if (input) wrap.sync(c[input.dataset.key]);
  }
}

// ---- Buttons -----------------------------------------------------------------

function actionSelect(rule, key, none) {
  const el = document.createElement('select');
  el.className = 'nk-input pick';
  for (const a of state.actions) {
    el.append(Object.assign(document.createElement('option'), { value: a.id, textContent: a.id === 'none' ? none : a.label }));
  }
  el.dataset.rule = key;
  el.value = rule[key];
  el.onchange = () => call('setButton', el.dataset.button, { [key]: el.value });
  return el;
}

function opt(label, control) {
  const wrap = document.createElement('div');
  wrap.className = 'opt';
  wrap.append(Object.assign(document.createElement('span'), { textContent: label }), control);
  return wrap;
}

let rulesShown = '';

function renderRules() {
  const list = $('rules');
  const entries = Object.entries(state.config.buttons).sort((a, b) => a[0] - b[0]);
  const signature = JSON.stringify([entries, state.actions.length]);
  if (signature === rulesShown) return; // rebuilding would replay the row animation and close an open dropdown
  rulesShown = signature;
  if (!entries.length) {
    list.replaceChildren();
    const empty = document.createElement('div');
    empty.className = 'nk-empty';
    empty.innerHTML = '<svg width="26" height="26"><use href="#i-mouse"/></svg><b>No buttons yet</b><span class="nk-muted nk-small">Add a button, then press it on your mouse.</span>';
    list.append(empty);
    return;
  }
  const focused = document.activeElement;
  const focusButton = focused?.dataset.button;
  const focusRule = focused?.dataset.rule;
  list.replaceChildren(...entries.map(([button, rule]) => {
    const row = document.createElement('div');
    row.className = 'nk-card nk-tight rule nk-in';
    const which = document.createElement('div');
    which.className = 'which';
    which.innerHTML = '<svg><use href="#i-mouse"/></svg>';
    which.append(buttonName(button));
    const click = actionSelect(rule, 'click', 'Default');
    const hold = actionSelect(rule, 'hold', 'Nothing');
    const drag = document.createElement('select');
    drag.className = 'nk-input pick';
    for (const [value, text] of [['none', 'Nothing'], ['spaces', 'Spaces & Mission Control']]) {
      drag.append(Object.assign(document.createElement('option'), { value, textContent: text }));
    }
    drag.value = rule.drag;
    drag.dataset.rule = 'drag';
    for (const el of [click, hold, drag]) {
      el.dataset.button = button;
      el.setAttribute('aria-label', `${buttonName(button)} button ${el.dataset.rule}`);
    }
    drag.onchange = () => call('setButton', button, { drag: drag.value });
    const remove = document.createElement('button');
    remove.className = 'nk-icon-btn';
    remove.title = 'Remove';
    remove.dataset.button = button;
    remove.dataset.rule = 'remove';
    remove.setAttribute('aria-label', `Remove ${buttonName(button)} button`);
    remove.innerHTML = '<svg><use href="#i-x"/></svg>';
    remove.onclick = () => call('removeButton', button);
    row.append(which, opt('Click', click), opt('Hold', hold), opt('Drag', drag), remove);
    return row;
  }));
  if (focusButton && focusRule) {
    const next = [...list.querySelectorAll('[data-button]')].find(el => el.dataset.button === focusButton && el.dataset.rule === focusRule);
    (next || $('learn')).focus();
  }
}

// ---- Page --------------------------------------------------------------------

function render() {
  if (!state) return;
  const c = state.config;
  if (!built) buildScroll();
  $('enabled').checked = c.enabled;
  syncScroll();
  renderRules();

  const pill = $('status');
  const needsPermission = c.enabled && !state.trusted;
  pill.className = `nk-pill ${!c.enabled ? '' : needsPermission ? 'nk-bad' : state.running ? 'nk-good' : 'nk-accent'}`;
  pill.lastElementChild.textContent = !c.enabled ? 'Off' : needsPermission ? 'Needs permission' : state.error ? 'Unavailable' : state.running ? 'Active' : 'Starting…';

  const learning = state.learning;
  $('learn').textContent = learning ? 'Cancel' : 'Add a button';
  $('learn').classList.toggle('nk-primary', !learning);
  $('learnHint').textContent = learning ? 'Press the mouse button you want to set up…' : '';
  $('learnHint').classList.toggle('learning', learning);

  if (needsPermission || (learning && !state.trusted)) {
    showError('Allow Nook in Accessibility so it can read your mouse.', { label: 'Open Settings', run: () => call('openPrivacy') });
  } else if (state.error && (c.enabled || learning)) {
    showError(state.error, { label: 'Retry', run: refresh });
  } else {
    showError('');
  }
  $('enabled').disabled = false;
  $('learn').disabled = false;
}

async function refresh() {
  try {
    state = await nook.mouse.state();
    render();
  } catch (err) {
    if (!state) {
      $('scroll').replaceChildren();
      built = false;
      $('status').lastElementChild.textContent = 'Unavailable';
    }
    showError(`Couldn't reach the mouse engine: ${err.message || err}`, { label: 'Retry', run: refresh });
  }
}

$('enabled').onchange = (e) => call('set', { enabled: e.target.checked });
$('learn').onclick = () => call('learn', !state?.learning);
$('view').onclick = (e) => {
  const b = e.target.closest('button[data-view]');
  if (!b) return;
  view = b.dataset.view;
  for (const x of $('view').children) x.classList.toggle('nk-on', x === b);
  $('scroll').hidden = view !== 'scroll';
  $('buttons').hidden = view !== 'buttons';
};

nook.on('mouse', (d) => {
  if (d.button !== undefined && state) {
    // Learned a button: add it (every action starts as "Default"; the user picks), unless it's already listed.
    if (!state.config.buttons[d.button]) call('setButton', String(d.button), {});
    else refresh();
  } else {
    refresh();
  }
});
nook.on('show', refresh);
nook.on('open', refresh);
nook.on('close', () => { if (state?.learning) call('learn', false); });
document.addEventListener('nk:alt', (event) => {
  const button = event.target.closest('button');
  if (button) { event.preventDefault(); button.click(); }
});
refresh();
