// Shipped plugin logic runs from /tmp with window.nook and a small in-memory DOM.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const folder = fs.mkdtempSync('/tmp/nook-cleaner-plugin-');
const plugin = path.resolve(__dirname, '../../Plugins/cleaner');
for (const name of ['main.js', 'shell.js', 'index.html']) fs.copyFileSync(path.join(plugin, name), path.join(folder, name));
function dom() {
  const ids = new Map();
  const document = { activeElement: null, handlers: {} };
  class Element {
    constructor(tag) { this.tagName = tag; this.children = []; this.dataset = {}; this.style = {}; this.handlers = {}; this.hidden = false; this.disabled = false; this._text = ''; }
    set id(value) { this._id = value; ids.set(value, this); }
    get id() { return this._id; }
    set textContent(value) { this._text = String(value); this.children = []; }
    get textContent() { return this._text + this.children.map((child) => child.textContent).join(''); }
    setAttribute(name, value) { this[name] = value; }
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this.children = children; this._text = ''; }
    addEventListener(name, handler) { (this.handlers[name] ||= []).push(handler); }
    fire(name, event = {}) { for (const handler of this.handlers[name] || []) handler(event); }
    focus() { document.activeElement = this; }
  }
  document.getElementById = (id) => ids.get(id);
  document.createElement = (tag) => new Element(tag);
  document.createElementNS = (_, tag) => new Element(tag);
  document.addEventListener = (name, handler) => { document.handlers[name] = handler; };
  for (const [, tag, id] of fs.readFileSync(path.join(folder, 'index.html'), 'utf8').matchAll(/<(\w+)[^>]*\bid="([^"]+)"/g)) {
    const element = new Element(tag); element.id = id;
  }
  return document;
}
const tick = async () => { for (let i = 0; i < 5; i++) await new Promise(setImmediate); };
async function setup({ finderFailure = false, nativeFailure = false, unknownSize = true } = {}) {
  const document = dom(), calls = [], opened = [], saved = [];
  const events = {};
  const nook = {
    settings: { get: async () => ({}) },
    storage: { get: async () => ({ version: 1, at: Date.now(), categories: { caches: { error: 'Old permission error' } } }), set: async (_, value) => saved.push(value) },
    system: async () => ({ disk: { total: 1000000, free: 500000 } }),
    on: async (event, callback) => { events[event] = callback; },
    open: async (url) => opened.push(url),
    cleaner: { clean: async (category, days) => {
      calls.push(category);
      assert.equal(days, 60);
      if (nativeFailure) throw new Error('Native service unavailable');
      return { bytes: 4096, moved: 1, skipped: 12, protectedCount: 12, failed: 0 };
    } },
    shell: async (command) => {
      if (command.includes('tell application "Finder" to empty trash')) {
        calls.push('trash');
        return finderFailure ? { code: 1, stderr: 'Not authorized to send Apple events to Finder. (-1743)', stdout: '' }
          : { code: 0, stdout: 'EMPTIED\n', stderr: '' };
      }
      const id = ['caches', 'logs', 'derived', 'devices', 'simulators', 'packages', 'brew', 'trash'].find((id) => command === api.scan(id, 60));
      assert.ok(id, 'Only fixed scans and explicitly confirmed Finder empty are allowed.');
      if (id === 'trash') return { code: 0, stdout: unknownSize ? 'UNKNOWN\n' : 'TOTAL\t0\t0\nSKIPPED\t0\t0\n', stderr: '' };
      if (id === 'brew') return { code: 0, stdout: 'UNAVAILABLE\tHomebrew is not installed\n', stderr: '' };
      return { code: 0, stdout: id === 'caches' ? 'TOTAL\t4096\t1\nSKIPPED\t12\t12\n' : 'TOTAL\t0\t0\nSKIPPED\t0\t0\n', stderr: '' };
    },
  };
  const context = vm.createContext({ document, nook, window: { nook }, console });
  vm.runInContext(fs.readFileSync(path.join(folder, 'shell.js'), 'utf8') + '\nglobalThis.api = CleanerShell;', context);
  const api = context.api;
  vm.runInContext(fs.readFileSync(path.join(folder, 'main.js'), 'utf8').replace('void start();', 'globalThis.started = start();'), context);
  await context.started;
  const evaluate = (code) => vm.runInContext(code, context);
  const key = (key, mods = {}) => {
    const event = { key, preventDefault() { this.prevented = true; }, ...mods };
    document.handlers.keydown(event);
    if (key === 'Enter' && !event.prevented && document.activeElement?.tagName === 'button' && !document.activeElement.disabled) document.activeElement.fire('click');
    return event;
  };
  return { document, calls, opened, saved, events, evaluate, key, get: (id) => document.getElementById(id) };
}
(async () => {
  try {
    const app = await setup();
    assert.equal(app.get('error').hidden, true);
    assert.equal(app.get('privacy-hint').hidden, false);
    assert.match(app.get('categories').textContent, /12 items skipped — protected by macOS/);
    assert.match(app.get('categories').textContent, /Size unknown/);
    assert.doesNotMatch(app.get('categories').textContent, /Old permission error/);
    assert.equal(app.saved.at(-1).version, 2);
    assert.equal(app.saved.at(-1).categories.caches.protectedCount, 12);
    app.get('open-privacy').fire('click'); await tick();
    assert.equal(app.opened[0], 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles');
    app.get('scan').focus(); app.key('ArrowUp');
    assert.equal(app.document.activeElement.id, 'select-trash');
    app.key('ArrowDown');
    assert.equal(app.document.activeElement.id, 'select-caches');
    app.key('ArrowDown');
    assert.equal(app.document.activeElement.id, 'select-logs');
    app.key('ArrowUp');
    assert.equal(app.document.activeElement.id, 'select-caches');
    app.key('Enter', { metaKey: true });
    assert.equal(app.get('confirmation').hidden, false);
    app.key('Escape');
    assert.equal(app.get('confirmation').hidden, true);
    app.get('clean').focus(); app.key('Enter');
    assert.equal(app.get('confirmation').hidden, false);
    // Native Enter activates the real confirmation button; protected skips are successful partial work.
    app.key('Enter'); await tick();
    assert.deepEqual(app.calls, ['caches']);
    assert.equal(app.get('error').hidden, true);
    assert.doesNotMatch(app.get('categories').textContent, /could not be moved/);
    assert.match(app.get('result-title').textContent, /Moved/);
    assert.match(app.get('result-detail').textContent, /12 items skipped — protected by macOS/);
    // Unknown Trash is independently selectable and always goes first when combined with cleanup.
    const trash = app.get('select-trash'); trash.checked = true; trash.fire('change');
    app.get('clean').fire('click');
    assert.match(app.get('confirm-text').textContent, /Permanently empty all existing Trash/);
    await app.evaluate('clean()');
    assert.deepEqual(app.calls.slice(-2), ['trash', 'caches']);
    assert.equal(app.get('select-trash').checked, false, 'Emptying Trash is opt-in for each run.');
    const denied = await setup({ finderFailure: true });
    denied.get('select-trash').checked = true; denied.get('select-trash').fire('change');
    denied.get('clean').fire('click'); await denied.evaluate('clean()');
    assert.deepEqual(denied.calls, ['trash'], 'Do not move new items after Finder fails or times out.');
    assert.match(denied.get('categories').textContent, /Allow Nook to control Finder.*Automation/);
    const failed = await setup({ nativeFailure: true });
    failed.get('clean').fire('click'); await failed.evaluate('clean()');
    assert.match(failed.get('categories').textContent, /Native service unavailable/);
    assert.throws(() => app.evaluate("parseMeasurement('TOTAL\\t4096\\t1\\nSKIPPED\\t2\\t3\\n')"));
    console.log('PASS: partial scan and clean, unknown Trash selection, one privacy hint/link, confirmations, keyboard, Finder denial, native errors, cache migration');
  } finally {
    fs.rmSync(folder, { recursive: true, force: true }); // /tmp copy only.
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
