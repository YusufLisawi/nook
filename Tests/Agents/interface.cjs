const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = process.argv[2];
const document = require('./dom.cjs')(fs.readFileSync(path.join(source, 'index.html'), 'utf8'));
const $ = id => document.getElementById(id);
const events = {}, frames = [], calls = [];
let savedSession;
const agent = { id: 'a', name: 'Reviewer', model: 'gpt-6.1-sol', workingDirectory: '~' };
const api = {
  plugin: { id: 'agents' }, on: (name, callback) => { (events[name] ||= []).push(callback); },
  settings: { get: async () => ({ recentChats: 5 }) },
  notch: { pin: async value => calls.push(['pin', value]), close: async () => calls.push(['close']) },
  activity: { set: async value => calls.push(['activity', value]), clear: async () => calls.push(['clear']) },
  open: async url => calls.push(['open', url]), clipboard: { write: async text => calls.push(['copy', text]) },
  agents: {
    list: async () => [agent], sessions: async () => [], open: async () => savedSession,
    send: async (agentId, sessionId, text) => {
      calls.push(['send', agentId, sessionId, text]);
      savedSession = { id: 's', agentId, title: text, revision: 1, updatedAt: 1, status: 'running', items: [{ id: 'u', type: 'user_message', text }] };
      return savedSession;
    },
    cancel: async id => calls.push(['cancel', id]),
    save: async value => { calls.push(['save', value]); return { ...value, id: 'b', model: 'gpt-6.1-sol' }; }
  }
};
const context = vm.createContext({ document, window: { nook: api }, nook: api, requestAnimationFrame: callback => frames.push(callback) });
for (const file of ['core.js', 'markdown.js', 'main.js']) vm.runInContext(fs.readFileSync(path.join(source, file), 'utf8'), context);
async function flush() {
  for (let index = 0; index < 4; index++) { await new Promise(setImmediate); while (frames.length) frames.shift()(); }
}
function key(value, metaKey = false) {
  const event = { key: value, metaKey, preventDefault() { this.prevented = true; }, stopPropagation() {} };
  for (const callback of document.events.keydown) callback(event);
  return event;
}
function emit(name, payload) { for (const callback of events[name] || []) callback(payload); }

(async () => {
  await flush();
  assert.equal($('loading').hidden, true);
  assert.equal($('agent-name').textContent, 'Reviewer');
  $('message').value = 'Review my code'; $('message').oninput(); await flush();
  assert.equal($('send').disabled, false);
  await $('composer').onsubmit({ preventDefault() {} }); await flush();
  assert.equal($('message').value, '');
  assert.equal($('stop').hidden, false);
  assert.equal(calls.some(c => c[0] === 'pin' && c[1]), true);
  const command = { id: 'cmd', type: 'command_execution', command: 'ls', status: 'in_progress', aggregated_output: 'live output' };
  emit('agentSession', { session: { id: 's', agentId: 'a', revision: 2, status: 'running' }, item: command }); await flush();
  let card = $('transcript').querySelector('details');
  assert.equal(card.textContent.includes('live output'), true);
  card.open = true;
  emit('agentSession', { session: { id: 's', agentId: 'a', revision: 3, status: 'running' }, item: { ...command, aggregated_output: 'finished', exit_code: 0, status: 'completed' } }); await flush();
  card = $('transcript').querySelector('details');
  assert.equal(card.open, true, 'Live updates preserve expanded cards');
  assert.equal(card.textContent.includes('Exit 0'), true);
  assert.equal(key('Escape').prevented, true); await flush();
  assert.equal(calls.some(c => c[0] === 'cancel' && c[1] === 's'), true);
  key('k', true); await flush();
  assert.equal($('switcher').hidden, false);
  assert.equal(document.activeElement, $('search'));
  key('ArrowDown'); key('Enter'); await flush();
  assert.equal($('switcher').hidden, true);
  key('n', true); await flush();
  assert.equal($('transcript').textContent.includes('What shall we work on?'), true);
  assert.deepEqual(calls.filter(c => c[0] === 'pin').at(-1), ['pin', false]);
  $('message').value = 'An unsent draft'; $('message').oninput(); await flush();
  await $('rail').querySelector('.session-row').onclick(); await flush();
  assert.equal($('message').value, '', 'A new-chat draft does not leak into an existing chat');
  key('n', true); await flush();
  assert.equal($('message').value, 'An unsent draft', 'Draft survives switching chats');
  $('add').onclick(); $('create-name').value = 'Writer';
  await $('create-form').onsubmit({ preventDefault() {} }); await flush();
  assert.equal($('create').hidden, true);
  assert.equal($('agent-name').textContent, 'Writer');
  assert.equal(calls.find(c => c[0] === 'save')[1].fullAccess, true);
  emit('show', 'home'); await flush();
  assert.deepEqual(calls.filter(c => c[0] === 'pin').at(-1), ['pin', false]);
  console.log('PASS: shipped plugin DOM, composer, tool updates, keyboard switch/stop/new, creation and leave/unpin');
})().catch(error => { console.error(error); process.exit(1); });
