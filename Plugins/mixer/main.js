// Mixer — output/mic devices + per-app volume. Engine: nook.audio.* (Core Audio process taps).
const $ = (id) => document.getElementById(id);
let state = null;
let view = 'output';
let settings = { maxBoost: '200%', showIdle: false };
let dragging = null; // id of the slider being dragged — don't redraw it from polled state
const pending = new Map(); // throttle slider writes

const pct = (v) => `${Math.round(v * 100)}%`;
const maxApp = () => Number.parseInt(settings.maxBoost, 10) / 100 || 2;

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
    const next = await nook.audio[fn](...args);
    if (next) { state = next; render(); }
    showPermission();
  } catch (err) {
    showError(`Couldn't ${fn.replace(/([A-Z])/g, ' $1').toLowerCase()}: ${err.message || err}`);
  } finally { $('loading').hidden = true; }
}

function showPermission() {
  if (state?.needsPermission) {
    showError('Allow Nook to capture app audio to change app volumes.', { label: 'Open Settings', run: () => nook.audio.openPrivacy() });
  } else if (!$('error').textContent.startsWith("Couldn't")) {
    showError('');
  }
}

/** Throttled writes while dragging (≤ 20/s), always sending the final value. */
function send(key, fn, ...args) {
  const entry = pending.get(key);
  if (entry) { entry.args = args; return; }
  call(fn, ...args);
  pending.set(key, { args: null });
  setTimeout(() => {
    const e = pending.get(key);
    pending.delete(key);
    if (e?.args) call(fn, ...e.args);
  }, 50);
}

// ---- Vertical slider ---------------------------------------------------------

function slider({ id, value, max, muted, onInput }) {
  const track = document.createElement('div');
  track.className = 'track';
  track.dataset.id = id;
  track.tabIndex = 0;
  track.setAttribute('role', 'slider');
  track.setAttribute('aria-orientation', 'vertical');
  track.setAttribute('aria-valuemin', '0');
  track.setAttribute('aria-valuemax', String(max * 100));
  track.setAttribute('aria-label', 'Volume');
  const fill = document.createElement('div');
  fill.className = 'fill';
  track.append(fill);
  if (max > 1) {
    const tick = document.createElement('div');
    tick.className = 'tick';
    tick.style.bottom = `${(1 / max) * 100}%`;
    track.append(tick);
  }
  const paint = (v) => {
    track.dataset.value = v;
    track.setAttribute('aria-valuenow', String(Math.round(v * 100)));
    track.setAttribute('aria-valuetext', muted ? `Muted, ${pct(v)}` : pct(v));
    fill.style.height = `${Math.min(1, v / max) * 100}%`;
    track.classList.toggle('boost', v > 1.001);
    track.classList.toggle('muted', !!muted);
  };
  paint(value);
  const valueAt = (e) => {
    const r = track.getBoundingClientRect();
    let v = ((r.bottom - e.clientY) / r.height) * max;
    if (max > 1 && Math.abs(v - 1) < 0.04) v = 1; // gentle snap to 100%
    return Math.round(Math.max(0, Math.min(max, v)) * 100) / 100;
  };
  track.addEventListener('keydown', (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey || !['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const current = Number(track.dataset.value ?? value);
    const delta = (event.shiftKey ? 0.1 : 0.01) * (['ArrowUp', 'ArrowRight'].includes(event.key) ? 1 : -1);
    const v = event.key === 'Home' ? 0 : event.key === 'End' ? max : Math.round(Math.max(0, Math.min(max, current + delta)) * 100) / 100;
    paint(v); onInput(v);
  });
  track.addEventListener('pointerdown', (e) => {
    dragging = id;
    track.setPointerCapture(e.pointerId);
    const v = valueAt(e); paint(v); onInput(v);
  });
  track.addEventListener('pointermove', (e) => {
    if (dragging !== id) return;
    const v = valueAt(e); paint(v); onInput(v);
  });
  const end = () => { if (dragging === id) dragging = null; };
  track.addEventListener('pointerup', end);
  track.addEventListener('pointercancel', end);
  track.addEventListener('wheel', (e) => { // two-finger scroll nudges the level
    e.preventDefault();
    const current = Number(track.dataset.value ?? value);
    const v = Math.round(Math.max(0, Math.min(max, current - e.deltaY * 0.004)) * 100) / 100;
    track.dataset.value = v; paint(v); onInput(v);
  }, { passive: false });
  track.dataset.value = value;
  return { track, paint };
}

function miniButton(symbol, title, onClick, cls = '') {
  const b = document.createElement('button');
  b.className = `mini ${cls}`;
  b.title = title;
  b.innerHTML = `<svg><use href="#${symbol}"/></svg>`;
  b.onclick = onClick;
  return b;
}

function channel({ id, name, head, value, max, muted, playing, onVolume, onMute, onReset, master }) {
  const el = document.createElement('div');
  el.className = `channel${master ? ' master' : ''}`;
  el.title = name;
  el.dataset.nkItem = id;
  el.setAttribute('role', 'group');
  el.setAttribute('aria-label', name);
  const top = document.createElement('div');
  top.className = 'head';
  top.append(head);
  if (playing) top.append(Object.assign(document.createElement('span'), { className: 'playing-dot' }));
  const label = Object.assign(document.createElement('div'), { className: 'name', textContent: name });
  const valueEl = Object.assign(document.createElement('span'), { className: 'value' });
  const setLabel = (v) => {
    valueEl.textContent = muted ? 'Muted' : (v > 1.001 ? `⚡${pct(v)}` : pct(v));
    valueEl.classList.toggle('boost', v > 1.001 && !muted);
  };
  setLabel(value);
  const { track } = slider({ id, value, max, muted, onInput: (v) => { setLabel(v); onVolume(v); } });
  track.setAttribute('aria-label', `${name} volume`);
  const foot = document.createElement('div');
  foot.className = 'foot';
  foot.append(
    miniButton('i-reset', 'Back to 100%', onReset, onReset && (value !== 1 || muted) ? '' : 'hide'),
    valueEl,
    miniButton(muted ? 'i-mute' : 'i-spk', muted ? 'Unmute' : 'Mute', onMute, muted ? 'on' : ''),
  );
  el.append(top, label, track, foot);
  return el;
}

// ---- Render -------------------------------------------------------------------

function render() {
  if (!state || dragging) return;
  const kind = view === 'output' ? 'output' : 'input';
  const devices = state[kind].devices;
  const current = devices.find((d) => d.isDefault);
  const picker = $('device');
  picker.replaceChildren(...devices.map((d) => Object.assign(document.createElement('option'), { value: d.uid, textContent: d.name, selected: d.isDefault })));
  picker.title = kind === 'output' ? 'Output device' : 'Microphone';
  const pinned = state[kind].preferredUID && state[kind].preferredUID === current?.uid;
  const pin = $('pin');
  pin.classList.toggle('on', !!pinned);
  pin.innerHTML = `<svg><use href="#${pinned ? 'i-pinf' : 'i-pin'}"/></svg>`;
  pin.title = pinned ? `Always using ${current?.name} — click to stop` : `Keep ${current?.name ?? 'this'} as the default, even if macOS switches`;

  $('output').hidden = view !== 'output';
  $('input').hidden = view !== 'input';
  if (view === 'output') renderOutput(current); else renderInput(current);
}

function renderOutput(device) {
  const strip = $('output');
  const items = [];
  if (device) {
    const spk = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    spk.innerHTML = `<use href="#${device.muted ? 'i-mute' : 'i-spk'}"/>`;
    items.push(channel({
      id: 'master', name: device.name, head: spk, master: true,
      value: device.volume ?? 1, max: 1, muted: device.muted,
      onVolume: (v) => send('master', 'setDeviceVolume', 'output', device.uid, v),
      onMute: () => call('setDeviceMute', 'output', device.uid, !device.muted),
    }));
  }
  items.push(Object.assign(document.createElement('div'), { className: 'divider' }));
  const apps = state.apps.filter((a) => settings.showIdle || a.playing || a.volume !== 1 || a.muted);
  for (const app of apps) {
    const img = Object.assign(document.createElement('img'), { src: app.icon, alt: '' });
    items.push(channel({
      id: app.id, name: app.name, head: img, playing: app.playing,
      value: Math.min(app.volume, maxApp()), max: maxApp(), muted: app.muted,
      onVolume: (v) => send(app.id, 'setAppVolume', app.id, v),
      onMute: () => call('setAppMute', app.id, !app.muted),
      onReset: () => call('resetApp', app.id),
    }));
  }
  if (!apps.length) {
    const empty = document.createElement('div');
    empty.className = 'nk-empty empty-apps';
    empty.innerHTML = '<b>No apps playing</b><span>Play something and it shows up here.</span>';
    items.push(empty);
  }
  strip.replaceChildren(...items);
}

function renderInput(device) {
  const vol = $('micVolume');
  const has = device && device.volume !== null && device.volume !== undefined;
  vol.disabled = !has;
  if (document.activeElement !== vol) vol.value = has ? Math.round(device.volume * 100) : 0;
  $('micValue').textContent = has ? `${vol.value}%` : 'Fixed';
  vol.oninput = () => {
    $('micValue').textContent = `${vol.value}%`;
    send('mic', 'setDeviceVolume', 'input', device.uid, vol.value / 100);
  };
  const preferred = state.input.preferredUID;
  $('mics').replaceChildren(...state.input.devices.map((d) => {
    const row = document.createElement('div');
    row.className = 'nk-item mic-row';
    row.dataset.nkItem = d.uid;
    row.setAttribute('aria-label', `${d.name}${d.isDefault ? ', selected' : ''}`);
    row.innerHTML = `<svg class="check ${d.isDefault ? '' : 'off'}"><use href="#i-check"/></svg>`;
    const name = Object.assign(document.createElement('span'), { className: 'nk-fill nk-ellipsis', textContent: d.name });
    row.append(name);
    if (preferred === d.uid) row.append(Object.assign(document.createElement('span'), { className: 'nk-pill nk-accent', textContent: 'Always' }));
    row.onclick = () => call('setDefault', 'input', d.uid);
    return row;
  }));
}

// ---- Wiring --------------------------------------------------------------------

$('device').onchange = (e) => call('setDefault', view === 'output' ? 'output' : 'input', e.target.value);
$('pin').onclick = () => {
  const kind = view === 'output' ? 'output' : 'input';
  const current = state?.[kind].devices.find((d) => d.isDefault);
  const pinned = state?.[kind].preferredUID === current?.uid;
  call('setPreferred', kind, pinned ? '' : current?.uid ?? '');
};
document.querySelectorAll('#view button').forEach((b) => {
  b.onclick = () => {
    view = b.dataset.view;
    document.querySelectorAll('#view button').forEach((x) => x.classList.toggle('nk-on', x === b));
    render();
  };
});

let visible = true;
const refresh = () => visible && !dragging && call('state');
nook.on('show', (tab) => { visible = tab === nook.plugin.id; refresh(); });
nook.on('open', (tab) => { visible = tab === nook.plugin.id; refresh(); });
nook.on('close', () => { visible = false; });
nook.on('audio', (next) => { if (!dragging) { state = next; render(); showPermission(); } });
nook.on('settings', (s) => { settings = { ...settings, ...s }; render(); });
nook.settings.get().then((s) => { settings = { ...settings, ...s }; }).catch(() => {});
setInterval(refresh, 1500);
refresh();
