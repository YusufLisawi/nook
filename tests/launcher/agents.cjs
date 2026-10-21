const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = process.argv[2];
const createDOM = require(process.argv[3]);
const document = createDOM(fs.readFileSync(path.join(source, 'index.html'), 'utf8'));
const frames = [], calls = [], events = {};
let fail = false;
const agent = { id: 'default', name: 'Default agent', model: 'test', workingDirectory: '/tmp' };
const api = {
  plugin: { id: 'agents' },
  on: (name, callback) => { (events[name] ||= []).push(callback); },
  settings: { get: async () => ({}) },
  notch: { pin: async value => calls.push(['pin', value]), close: async () => {} },
  activity: { set: async () => {}, clear: async () => {} },
  agents: {
    list: async () => [agent], sessions: async () => [],
    send: async (agentId, sessionId, text) => {
      if (fail) throw new Error('Agent not available');
      calls.push(['send', agentId, sessionId, text]);
      return { id: 'chat', agentId, title: text, revision: 1, status: 'running', updatedAt: 1, items: [] };
    },
    open: async () => {}, cancel: async () => {}
  }
};
const context = vm.createContext({ document, window: { nook: api }, nook: api, requestAnimationFrame: callback => frames.push(callback) });
for (const file of ['core.js', 'markdown.js', 'main.js']) vm.runInContext(fs.readFileSync(path.join(source, file), 'utf8'), context);
async function flush() { for (let i = 0; i < 4; i++) { await new Promise(setImmediate); while (frames.length) frames.shift()(); } }
(async () => {
  // Deliberately call before the normal startup async load completes.
  const prompt = 'Explain "this"\n$(literal) `text` 💡';
  await context.window.nookLauncherAsk(agent.id, prompt);
  await flush();
  assert.deepEqual(calls.filter(call => call[0] === 'send'), [['send', 'default', null, prompt]]);
  assert.equal(document.getElementById('agent-name').textContent, 'Default agent');
  assert.ok(calls.some(call => call[0] === 'pin' && call[1]));
  fail = true;
  await assert.rejects(context.window.nookLauncherAsk(agent.id, 'second query'), /Agent not available/);
  await flush();
  assert.ok(calls.some(call => call[0] === 'pin' && !call[1]));
  console.log('PASS: launcher cold-start agent handoff, literal query, default agent, pin and failure propagation');
})().catch(error => { console.error(error); process.exitCode = 1; });
