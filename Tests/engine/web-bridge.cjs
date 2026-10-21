const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const repo = process.argv[2];
const swift = fs.readFileSync(path.join(repo, 'Nook/Core/PluginEngine/PluginEngine.swift'), 'utf8');
const source = swift.match(/static let javascript = """([\s\S]*?)"""/)[1];

(async () => {
  const calls = [], subscriptions = {};
  const n = { plugin: { apiVersion: 2 }, host: { call(method, params) { calls.push([method, params]); return Promise.resolve('result'); } }, native: { call() {} }, notch: {}, on(event, callback) { subscriptions[event] = callback; } };
  vm.runInNewContext(source, { window: { nook: n } });
  await n.ai.complete({ prompt: 'Hello' });
  await n.files.read({ path: 'draft.txt' });
  await n.notch.open();
  n.native.on('ready', () => {});
  assert.equal(calls[0][0], 'ai.complete'); assert.equal(calls[0][1].prompt, 'Hello');
  assert.equal(calls[1][0], 'files.read'); assert.equal(calls[1][1].path, 'draft.txt');
  assert.equal(calls[2][0], 'notch.open'); assert.ok(subscriptions['native:ready']);
  const legacyOpen = () => {};
  const legacy = { plugin: { apiVersion: 1 }, native: {}, files: { open: legacyOpen }, on() {} };
  vm.runInNewContext(source, { window: { nook: legacy } });
  assert.equal(legacy.files.open, legacyOpen, 'v1 namespaces are preserved');

  const elements = Object.fromEntries(['loading', 'empty', 'error', 'run', 'result'].map(id => [id, { hidden: true, disabled: false, textContent: '', listeners: {}, addEventListener(event, callback) { this.listeners[event] = callback; } }]));
  let failure = true;
  const events = {};
  vm.runInNewContext(fs.readFileSync(path.join(repo, 'store/templates/web/main.js'), 'utf8'), {
    document: { getElementById: id => elements[id] },
    nook: { plugin: { name: 'Test' }, on(e, cb) { events[e] = cb; }, native: {
      on(e, cb) { events[e] = cb; }, async call() { if (failure) throw new Error('Disconnected'); return { message: 'Hello' }; },
    } },
  });
  await new Promise(resolve => setImmediate(resolve));
  assert.match(elements.error.textContent, /Disconnected/); assert.equal(elements.error.hidden, false);
  assert.equal(elements.run.disabled, false);
  failure = false; await events.ready();
  assert.equal(elements.error.hidden, true); assert.equal(elements.result.textContent, 'Hello');
  assert.equal(elements.loading.hidden, true); assert.equal(elements.empty.hidden, true);
  let prevented = false;
  elements.run.listeners.keydown({ key: 'Enter', metaKey: true, preventDefault() { prevented = true; } });
  assert.ok(prevented);
  console.log('PASS: v2 web aliases/native events, v1 preservation, scaffold loading/error/retry/ready and Command-Enter with mocked window.nook.');
})().catch(error => { console.error(error); process.exitCode = 1; });
