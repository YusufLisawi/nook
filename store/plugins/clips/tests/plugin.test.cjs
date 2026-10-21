// Node's built-in VM, a small DOM fixture, and mocked window.nook; no browser or app is opened.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const root = fs.mkdtempSync(path.join('/tmp', 'nook-clips-plugin-'));
const plugin = path.resolve(__dirname, '..');
for (const file of ['main.js', 'logic.js', 'index.html']) fs.copyFileSync(path.join(plugin, file), path.join(root, file));

class Element {
  constructor(tag = 'div', id = '') {
    this.tagName = tag; this.id = id; this.children = []; this.dataset = {}; this.attributes = {}; this.style = {};
    this.hidden = false; this.disabled = false; this.value = ''; this.textContent = ''; this._classes = new Set();
    this.classList = { toggle: (name, force) => { if (force ?? !this._classes.has(name)) this._classes.add(name); else this._classes.delete(name); }, contains: (name) => this._classes.has(name) };
  }
  set className(value) { this._classes = new Set(value.split(' ')); }
  get className() { return [...this._classes].join(' '); }
  setAttribute(key, value) { this.attributes[key] = value; }
  append(...nodes) { for (const node of nodes) { this.children.push(node); node.parent = this; } }
  replaceChildren(...nodes) { this.children = []; this.append(...nodes); }
  contains(node) { return this === node || this.children.some((child) => child.contains(node)); }
  closest(selector) {
    if (selector === 'button' && this.tagName === 'button') return this;
    if (selector === '[role="tablist"]' && this.attributes.role === 'tablist') return this;
    return this.parent?.closest(selector) || null;
  }
  focus() { document.activeElement = this; this.onfocus?.(); }
  scrollIntoView() {}
  set innerHTML(value) {
    // The plugin uses one static, trusted skeleton for each option; its content uses textContent.
    this.replaceChildren(); this.parts = {};
    const icon = new Element(), copy = new Element(), title = new Element(), meta = new Element(), caption = new Element(), pin = new Element();
    icon.className = 'clip-icon'; title.className = 'clip-title'; meta.className = 'clip-meta'; pin.className = 'pin';
    this.append(icon, copy); copy.append(title, meta); meta.append(caption, pin);
    this.parts = { '.clip-icon': icon, '.clip-title': title, '.clip-meta > span': caption, '.pin': pin };
    if (value.includes('<img')) { const image = new Element('img'); image.hidden = true; icon.append(image); this.parts.img = image; }
  }
  querySelector(selector) { return this.parts?.[selector] || this.querySelectorAll(selector)[0] || null; }
  querySelectorAll(selector) {
    const all = this.children.flatMap((child) => [child, ...child.querySelectorAll('*')]);
    if (selector === '*') return all;
    if (selector === 'button:not(:disabled)') return all.filter((node) => node.tagName === 'button' && !node.disabled);
    return [];
  }
}
const ids = {}, documentEvents = {}, events = {}, timers = new Map();
const document = { activeElement: null, getElementById: (id) => ids[id], createElement: (tag) => new Element(tag), addEventListener: (event, callback) => { documentEvents[event] = callback; } };
for (const [, tag, id, rest] of fs.readFileSync(path.join(root, 'index.html'), 'utf8').matchAll(/<(\w+) id="([^"]+)"([^>]*)>/g)) {
  ids[id] = new Element(tag, id); ids[id].hidden = rest.includes('hidden');
}
const tabs = new Element(); tabs.setAttribute('role', 'tablist'); tabs.append(ids.clipboard, ids.screenshots);
const stamp = Date.parse('2026-10-21T12:03:00Z');
const entry = (id, extras = {}) => ({ id, kind: 'text', name: id, text: id, source: 'Fixture', date: stamp, hasFile: false, pinned: false, ...extras });
let history = [entry('second', { date: stamp + 100 }), entry('pinned', { pinned: true }), entry('third')];
let captures = Array.from({ length: 5 }, (_, i) => entry(`shot-${i}`, { kind: 'screenshot', hasFile: true, date: stamp - i }));
let state = { enabled: true }, failHistory = false, historyImpl;
const calls = [];
const clips = {
  history: async (query) => { calls.push(['history', query]); if (historyImpl) return historyImpl(query); if (failHistory) throw new Error('Fixture read failed'); return history; },
  screenshots: async (query) => { calls.push(['screenshots', query]); return captures; },
  status: async () => state,
  thumbnail: async (id) => { calls.push(['thumbnail', id]); return null; }
};
for (const action of ['copy', 'paste', 'open', 'reveal', 'quickLook', 'pin', 'unpin', 'delete']) clips[action] = async (id) => { calls.push([action, id]); if (action === 'delete') captures = captures.filter((item) => item.id !== id); };
const nook = { clips, notch: { close: async () => { calls.push(['close']); } }, on: (event, callback) => { events[event] = callback; } };
let timerID = 0;
nook.native = {call: (method, p) => method.endsWith('Page') ? Promise.resolve(nook.clips[method.split('.')[1].replace('Page', '')](p.args[0])).then(items => ({items, next:null})) : nook.clips[method.split('.')[1]](...p.args), on: nook.on};
const context = vm.createContext({ document, nook, window: { nook, innerWidth: 650 }, console, Date, Map, Set,
  setTimeout: (callback, delay) => { timers.set(++timerID, { callback, delay }); return timerID; }, clearTimeout: (id) => timers.delete(id) });
const settle = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function key(value, target = ids.search, options = {}) {
  const event = { key: value, target, ...options, preventDefault() { this.defaultPrevented = true; }, stopPropagation() {} };
  documentEvents.keydown(event); return event;
}
const selection = () => ids.content.children.find((row) => row.attributes['aria-selected'] === 'true')?.dataset.id;

(async () => {
  for (const file of ['logic.js', 'main.js']) vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), context, { filename: path.join(root, file) });
  await settle();
  assert.equal(selection(), 'pinned'); assert.equal(ids.loading.hidden, true); assert.equal(ids.content.hidden, false);
  key('ArrowDown'); assert.equal(selection(), 'second');
  key('Enter'); await settle(); assert.deepEqual(calls.at(-1), ['copy', 'second']);
  key('Enter', ids.search, { metaKey: true }); await settle(); assert.deepEqual(calls.at(-1), ['paste', 'second']);
  key('k', ids.search, { metaKey: true }); assert.equal(ids.menu.hidden, false);
  assert.equal(ids.menu.children.find((button) => button.textContent === 'Open').disabled, true);
  key('ArrowDown', document.activeElement); assert.equal(document.activeElement.textContent, 'Paste into App');
  key('Escape', document.activeElement); assert.equal(ids.menu.hidden, true);
  assert(!calls.some((call) => call[0] === 'close'), 'Escape dismisses actions before closing the notch');
  key('Escape'); await settle(); assert.deepEqual(calls.at(-1), ['close']);
  assert.equal(ids.content.attributes['aria-activedescendant'], ids.content.children.find((row) => row.dataset.id === selection()).id);
  assert(ids.content.children.every((row) => row.tabIndex === -1), 'The listbox is the single tab stop and announces its selected option');
  ids.content.children[0].onclick(); assert.equal(document.activeElement, ids.content);
  await events.clips(); await settle();
  assert.equal(document.activeElement, ids.content, 'Background refresh keeps keyboard focus on the listbox');

  failHistory = true; await events.clips(); await settle();
  assert.equal(ids.error.hidden, false); assert.equal(ids.errorText, undefined);
  assert.equal(ids['error-text'].textContent, 'Fixture read failed'); assert.equal(ids.content.children.length, 3);
  failHistory = false; state.enabled = false; await events.clips(); await settle();
  assert.equal(ids.notice.hidden, false); assert.match(ids.notice.textContent, /paused/);

  ids.search.value = 'name:invoice date:today'; ids.search.oninput();
  for (const [id, timer] of [...timers]) if (timer.delay === 120) { timers.delete(id); timer.callback(); }
  await settle(); assert(calls.some((call) => call[0] === 'history' && call[1] === 'name:invoice date:today'));

  // A stale response must never replace results from a later query.
  const delayed = [];
  historyImpl = () => new Promise((resolve) => delayed.push(resolve));
  const older = events.clips(), newer = events.clips();
  delayed[1]([entry('newest')]); await settle(); delayed[0]([entry('stale')]); await Promise.all([older, newer]);
  assert.equal(selection(), 'newest'); historyImpl = null;

  ids.screenshots.onclick(); await settle(); assert.equal(selection(), 'shot-0');
  assert(ids.content.classList.contains('grid'));
  key('ArrowDown'); assert.equal(selection(), 'shot-3');
  key('ArrowRight', ids.content); assert.equal(selection(), 'shot-4');
  key(' ', ids.content); await settle(); assert.deepEqual(calls.at(-1), ['quickLook', 'shot-4']);
  key('k', ids.search, { metaKey: true });
  ids.menu.children.find((button) => button.textContent === 'Move to Trash…').onclick();
  assert.equal(ids.confirmation.hidden, false); assert(!calls.some((call) => call[0] === 'delete'));
  ids.cancel.onclick(); assert.equal(ids.confirmation.hidden, true);
  key('k', ids.search, { metaKey: true }); ids.menu.children.at(-1).onclick(); ids.delete.onclick();
  await settle(); assert(calls.some((call) => call[0] === 'delete' && call[1] === 'shot-4'));
  assert.equal(ids.content.children.length, 4);
  key('ArrowLeft', ids.screenshots); await settle(); assert.equal(ids.clipboard.attributes['aria-selected'], 'true');

  history = []; await events.clips(); await settle(); assert.equal(ids.empty.hidden, false); assert.equal(ids.actions.disabled, true);
  state.clipboardLoading = true; await events.clips(); await settle();
  assert.equal(ids.loading.hidden, false); assert.equal(ids.empty.hidden, true);
  state.clipboardLoading = false;
  history = Array.from({ length: 300 }, (_, i) => entry(`clip-${i}`, { date: stamp - i }));
  await events.clips(); await settle(); assert.equal(ids.content.children.length, 300);
  key('ArrowDown', ids.content); assert.equal(selection(), 'clip-1');
  nook.notch.close = async () => { throw new Error('Fixture close failed'); };
  key('Escape'); await settle(); assert.equal(ids['error-text'].textContent, 'Fixture close failed');
  assert.equal(context.ClipsUI.move(-1, 'ArrowDown', 0), -1);
  assert.equal(context.ClipsUI.move(3, 'ArrowDown', 5, 3), 4);
  assert.match(context.ClipsUI.captions(stamp, new Date(stamp)), /^Today at/);
  assert.throws(() => context.ClipsUI.normalize({}), /invalid history/);
  delete nook.native; await events.clips(); await settle(); assert.match(ids['error-text'].textContent, /needs the native helper/);
  console.log('PASS: mocked window.nook in /tmp — 0/3/300 items, loading/empty/error/ready, pins, list/grid arrows, Enter, Command-Enter, Command-K, Escape, focus/ARIA, Quick Look, confirmation, search forwarding, stale responses, failure recovery');
})().catch((error) => { console.error(error); process.exitCode = 1; }).finally(() => fs.rmSync(root, { recursive: true, force: true })); // test-owned /tmp only
