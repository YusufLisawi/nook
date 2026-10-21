import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, cp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import vm from 'node:vm';

const tick = () => new Promise(setImmediate);
async function mock(run, options = {}) {
  const temporary = await mkdtemp('/tmp/nook-plugin-mock-');
  await cp(new URL('../plugins/word-count/', import.meta.url), temporary, { recursive: true });
  const elements = new Map(), events = new Map(), documentEvents = new Map(), timers = new Map();
  function element(id) {
    if (!elements.has(id)) elements.set(id, { value: '', textContent: '', hidden: false, disabled: true, listeners: {},
      addEventListener(event, listener) { this.listeners[event] = listener; }, focus() { this.focused = true; } });
    return elements.get(id);
  }
  let saved = options.draft ?? null, copied, loadError = !!options.loadError, saveError = false, copyError = false, hold, loadHold, reads = 0;
  const writes = [];
  const nook = {
    storage: {
      async get() { reads++; if (loadHold) await loadHold; if (loadError) throw new Error('disk unavailable'); return saved; },
      async set(key, value) { writes.push(value); if (hold) await hold; if (saveError) throw new Error('disk full'); saved = value; },
    },
    settings: { async get() { return { showCharacters: true }; } },
    clipboard: { async write(value) { if (copyError) throw new Error('clipboard busy'); copied = value; } },
    on(event, callback) { events.set(event, callback); },
  };
  const context = { window: { nook, addEventListener() {} }, document: { getElementById: element, addEventListener(event, cb) { documentEvents.set(event, cb); } },
    setTimeout(fn) { const id = Symbol(); timers.set(id, fn); return id; }, clearTimeout(id) { timers.delete(id); } };
  const api = { element, writes, events,
    input(value) { element('draft').value = value; element('draft').listeners.input(); },
    async flush() { const callbacks = [...timers.values()]; timers.clear(); callbacks.forEach((f) => f()); await tick(); },
    key(event) { documentEvents.get('keydown')({ preventDefault() {}, ...event }); },
    get saved() { return saved; }, get copied() { return copied; },
    get reads() { return reads; }, set loadHold(value) { loadHold = value; },
    set loadError(value) { loadError = value; }, set saveError(value) { saveError = value; }, set copyError(value) { copyError = value; }, set hold(value) { hold = value; },
  };
  try {
    vm.runInNewContext(await readFile(join(temporary, 'main.js'), 'utf8'), context, { filename: join(temporary, 'main.js') });
    await tick();
    await run(api);
  } finally { await rm(temporary, { recursive: true, force: true }); }
}

test('empty, ready, Unicode counts, live settings and keyboard copy', async () => mock(async (m) => {
  assert.equal(m.element('loading').hidden, true);
  assert.equal(m.element('draft').disabled, false);
  assert.equal(m.element('empty').hidden, false);
  m.input('Hello 🌍');
  assert.equal(m.element('counts').textContent, '2 words · 7 characters');
  assert.equal(m.element('empty').hidden, true);
  await m.flush();
  assert.equal(m.saved, 'Hello 🌍');
  m.events.get('settings')({ showCharacters: false });
  assert.equal(m.element('counts').textContent, '2 words');
  m.key({ metaKey: true, key: 'Enter' });
  await tick();
  assert.equal(m.copied, '2 words');
  m.events.get('show')();
  assert.equal(m.element('draft').focused, true);
}));

test('load failure keeps editor disabled and retry recovers', async () => mock(async (m) => {
  assert.equal(m.element('error').hidden, false);
  assert.equal(m.element('draft').disabled, true);
  m.loadError = false;
  m.element('retry').listeners.click();
  await tick();
  assert.equal(m.element('draft').disabled, false);
  assert.equal(m.element('error').hidden, true);
}, { loadError: true }));

test('concurrent retries cannot overwrite a newer draft; focus waits for loading', async () => mock(async (m) => {
  let release;
  m.loadError = false;
  m.loadHold = new Promise((resolve) => { release = resolve; });
  m.events.get('show')();
  m.element('retry').listeners.click();
  m.element('retry').listeners.click();
  assert.equal(m.reads, 2); // Initial failed read plus a single retry.
  assert.equal(m.element('retry').disabled, true);
  release(); await tick();
  assert.equal(m.element('draft').focused, true);
  m.input('new draft'); await m.flush();
  assert.equal(m.saved, 'new draft');
}, { loadError: true }));

test('failed saves retain the draft and retry saves the latest edit', async () => mock(async (m) => {
  m.saveError = true;
  m.input('first'); await m.flush();
  assert.equal(m.element('status').textContent, 'Unsaved');
  assert.equal(m.element('draft').value, 'first');
  m.input('latest');
  m.saveError = false;
  m.element('retry').listeners.click();
  await tick();
  assert.equal(m.saved, 'latest');
  assert.equal(m.element('error').hidden, true);
}));

test('serializes in-flight writes and flushes on close', async () => mock(async (m) => {
  let release;
  m.hold = new Promise((resolve) => { release = resolve; });
  m.input('older'); await m.flush();
  m.input('newest'); await m.flush();
  assert.deepEqual(m.writes, ['older']);
  m.hold = null; release(); await tick();
  assert.deepEqual(m.writes, ['older', 'newest']);
  assert.equal(m.saved, 'newest');
  m.input('closed'); m.events.get('close')(); await tick();
  assert.equal(m.saved, 'closed');
}));

test('clipboard failure is recoverable', async () => mock(async (m) => {
  m.copyError = true;
  m.element('copy').listeners.click(); await tick();
  assert.match(m.element('error').textContent, /copy counts/);
  m.copyError = false;
  m.element('retry').listeners.click(); await tick();
  assert.equal(m.copied, '0 words · 0 characters');
  assert.equal(m.element('error').hidden, true);
}));
