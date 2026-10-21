const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = process.argv[2];
const calls = [];
let response, failSend = false, openResolvers = {};
const api = {
  agents: {
    list: async () => [{ id: 'a', name: 'Reviewer' }, { id: 'b', name: 'Writer' }],
    sessions: async () => [],
    open: id => new Promise(resolve => { openResolvers[id] = resolve; }),
    send: async (...args) => { calls.push(['send', ...args]); if (failSend) throw Error('Sign in to Codex'); return response; },
    cancel: async id => calls.push(['cancel', id])
  },
  notch: { pin: async value => calls.push(['pin', value]) },
  activity: { set: async value => calls.push(['activity', value]), clear: async () => calls.push(['clear']) },
  clipboard: { write: async text => calls.push(['copy', text]) }
};
const context = vm.createContext({ window: { nook: api }, nook: api });
vm.runInContext(fs.readFileSync(path.join(source, 'core.js'), 'utf8'), context);
const Client = context.AgentsClient;

// Minimal DOM for Markdown: no browser, external scripts or GUI automation.
class Element {
  constructor(tag = '') { this.tagName = tag.toUpperCase(); this.children = []; this.value = ''; }
  append(...children) { this.children.push(...children); }
  set textContent(value) { this.value = String(value); this.children = []; }
  get textContent() { return this.value + this.children.map(c => c.textContent ?? String(c)).join(''); }
  addEventListener() {}
  setAttribute() {}
}
context.document = {
  createElement: tag => new Element(tag), createTextNode: text => ({ textContent: text }), createDocumentFragment: () => new Element()
};
vm.runInContext(fs.readFileSync(path.join(source, 'markdown.js'), 'utf8'), context);

(async () => {
  const client = new Client(context.window.nook);
  await client.load();
  assert.equal(client.loading, false);
  assert.equal(client.agentId, 'a');
  await client.leave();
  assert.equal(calls.length, 0, 'An inactive Agents view cannot unpin another plugin');
  response = { id: 'one', agentId: 'a', revision: 1, status: 'running', items: [{ id: 'u', type: 'user_message', text: 'Hi' }] };
  assert.equal(await client.send('Hi'), true);
  assert.equal(client.sessionId, 'one');
  assert.deepEqual(calls.find(c => c[0] === 'pin'), ['pin', true]);
  assert.equal(await client.send('duplicate'), false);
  client.apply({ id: 'one', agentId: 'a', revision: 3, status: 'done' }, { id: 'cmd', type: 'command_execution', aggregated_output: 'done' });
  client.apply({ id: 'one', agentId: 'a', revision: 2, status: 'running' }, { id: 'cmd', aggregated_output: 'stale' });
  assert.equal(client.session.status, 'done');
  assert.equal(client.session.items.find(i => i.id === 'cmd').aggregated_output, 'done');
  assert.equal(client.session.items.length, 2);
  // A bridge reply can arrive after a newer streamed item; it must never reset the transcript.
  response = { id: 'one', agentId: 'a', revision: 1, status: 'running', items: [] };
  await client.send('follow-up');
  assert.equal(client.session.items.length, 2);
  failSend = true;
  assert.equal(await client.send('retry'), false);
  assert.equal(client.error, 'Sign in to Codex');
  assert.equal(calls.at(-1)[0], 'pin'); assert.equal(calls.at(-1)[1], false);
  failSend = false;
  const first = client.select('a', 'slow');
  await new Promise(setImmediate);
  const second = client.select('b', 'fast');
  await new Promise(setImmediate);
  openResolvers.fast({ id: 'fast', agentId: 'b', status: 'done', revision: 1, items: [] });
  await second;
  openResolvers.slow({ id: 'slow', agentId: 'a', status: 'done', revision: 1, items: [] });
  await first;
  assert.equal(client.sessionId, 'fast', 'A slow open cannot steal selection');
  client.apply({ id: 'fast', agentId: 'b', revision: 2, status: 'running' });
  await client.cancel();
  assert.deepEqual(calls.at(-1), ['cancel', 'fast']);
  await client.activity();
  assert.equal(calls.at(-1)[1].text, 'Writer…');
  const pinsBeforeLeave = calls.filter(c => c[0] === 'pin').length;
  await client.leave();
  assert.equal(calls.filter(c => c[0] === 'pin').length, pinsBeforeLeave, 'Repeated leave events do not release someone else\'s pin');
  client.apply({ id: 'fast', agentId: 'b', revision: 3, status: 'done' });
  await client.activity(); assert.deepEqual(calls.at(-1), ['clear']);
  const md = context.agentMarkdown('# Heading\n- first\n- second\n```js\n<script>alert(1)</script>\n```\n[bad](javascript:alert(1)) **bold**');
  const flat = element => [element, ...(element.children || []).flatMap(flat)];
  const nodes = flat(md);
  assert.equal(nodes.some(n => n.tagName === 'SCRIPT'), false, 'Model HTML is inert text');
  assert.equal(nodes.some(n => n.tagName === 'A'), false, 'Unsafe URLs do not become links');
  assert.equal(nodes.filter(n => n.tagName === 'LI').length, 2);
  assert.equal(nodes.some(n => n.tagName === 'STRONG'), true);
  await nodes.find(n => n.tagName === 'BUTTON').onclick();
  assert.equal(calls.at(-1)[1], '<script>alert(1)</script>');
  console.log('PASS: mocked window.nook state, streaming order, resume races, errors, cancel, activity and safe Markdown');
})().catch(error => { console.error(error); process.exit(1); });
