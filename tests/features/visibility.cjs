const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const root = process.argv[2];
const flush = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  for (const id of ['monitor', 'home', 'mixer']) {
    const folder = path.join(root, 'Plugins', id);
    const dom = new JSDOM(fs.readFileSync(path.join(folder, 'index.html'), 'utf8'), { runScripts: 'outside-only', pretendToBeVisual: true });
    const w = dom.window, listeners = {}, intervals = new Map();
    let serial = 0, calls = 0;
    w.setInterval = callback => { const key = ++serial; intervals.set(key, callback); return key; };
    w.clearInterval = key => intervals.delete(key);
    w.HTMLCanvasElement.prototype.getContext = () => new Proxy({}, { get: (_, name) => name === 'createLinearGradient' ? () => ({ addColorStop() {} }) : () => {} });
    const metrics = { cpu: { usage: 0, cores: 8 }, memory: { used: 1, total: 2 }, disk: { used: 1, total: 2, free: 1 }, network: { downBps: 0, upBps: 0 }, load: [0, 0, 0], uptime: 60, thermal: 'nominal', battery: null };
    const counter = value => async () => { calls++; return value; };
    w.nook = {
      plugin: { id }, on: (event, callback) => (listeners[event] ||= []).push(callback),
      settings: { get: async () => ({}) }, storage: { get: async () => [], set: async () => {} },
      system: counter(metrics), shell: counter({ code: 0, stdout: '', stderr: '' }),
      timer: { state: counter({ running: false, text: '00:00' }) },
      audio: { state: counter({ output: { devices: [] }, input: { devices: [] }, apps: [] }) },
      features: { list: async () => [{ id: 'monitor', enabled: true }, { id: 'timers', enabled: true }] }
    };
    w.eval(fs.readFileSync(path.join(folder, 'main.js'), 'utf8'));
    await flush();
    assert(intervals.size > 0, id + ' creates intervals while visible');
    const queuedCallbacks = [...intervals.values()];
    for (const callback of listeners.show || []) callback('other-tab');
    await flush();
    assert.equal(intervals.size, 0, id + ' removes intervals immediately on tab switch');
    const hiddenCalls = calls;
    for (const callback of queuedCallbacks) callback();
    await flush();
    assert.equal(calls, hiddenCalls, id + ' rejects callbacks already queued before hiding');
    for (const callback of listeners.open || []) callback(id);
    await flush();
    assert(intervals.size > 0, id + ' resumes on reopen');
    for (const callback of listeners.close || []) callback(id);
    assert.equal(intervals.size, 0, id + ' removes intervals on close');
    if (id === 'home') {
      for (const callback of listeners.features || []) callback([{ id: 'monitor', enabled: false }, { id: 'timers', enabled: false }]);
      for (const callback of listeners.open || []) callback(id);
      await flush();
      const disabledCalls = calls;
      for (const callback of intervals.values()) callback();
      await flush();
      assert.equal(calls, disabledCalls, 'Home never invokes disabled feature APIs');
      assert(w.document.querySelector('.side').hidden, 'Home hides controls for disabled features');
    }
    dom.window.close();
    console.log(`PASS ${id}: visibility, interval teardown, queued callback guard and reopening with mocked window.nook`);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
