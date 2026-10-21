// No browser, WebKit or live Nook. Run a copy under /tmp with a mocked window.nook and DOM.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'nook-windows-plugin-'));
const source = path.join(folder, 'main.js');
fs.copyFileSync(path.join(__dirname, '../../Plugins/windows/main.js'), source);
const code = fs.readFileSync(source, 'utf8');

class Element {
  constructor(tag, document) {
    this.tagName = tag;
    this.document = document;
    this.children = [];
    this.dataset = {};
    this.handlers = {};
    this.className = '';
    this.value = '';
    this.hidden = false;
    this.disabled = false;
    this.textContent = '';
    this.classList = { toggle: (name, enabled) => {
      const classes = new Set(this.className.split(' ').filter(Boolean));
      enabled ? classes.add(name) : classes.delete(name);
      this.className = [...classes].join(' ');
    } };
  }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  querySelectorAll(tag) { return this.children.flatMap((child) => [ ...(child.tagName === tag ? [child] : []), ...child.querySelectorAll(tag) ]); }
  addEventListener(name, handler) { (this.handlers[name] ||= []).push(handler); }
  fire(name, event = {}) { for (const handler of this.handlers[name] || []) handler(event); }
  focus() { this.document.activeElement = this; this.fire('focus'); }
  scrollIntoView() {}
}

const ids = ['target', 'settings', 'search', 'error', 'loading', 'empty', 'emptyTitle', 'emptyMessage', 'privacy', 'retry', 'actions', 'hint'];
const actionIDs = ['previousDisplay', 'nextDisplay', 'previousDesktop', 'nextDesktop', 'leftHalf', 'rightHalf', 'topHalf', 'bottomHalf', 'topLeftQuarter', 'topRightQuarter', 'bottomLeftQuarter', 'bottomRightQuarter', 'firstThird', 'centerThird', 'lastThird', 'firstTwoThirds', 'lastTwoThirds', 'maximize', 'almostMaximize', 'maximizeHeight', 'maximizeWidth', 'center', 'restore'];
const actions = actionIDs.map((id, index) => ({ id, title: id.replace(/([A-Z])/g, ' $1'), group: index < 4 ? 'Displays & Desktops' : 'Layouts', shortcut: index === 0 ? '⌘⌥←' : '', conflict: '' }));
const ready = () => ({ trusted: true, target: 'Editor', busy: false, lastError: '', actions });
const tick = async () => { for (let i = 0; i < 4; i++) await new Promise(setImmediate); };

async function setup(overrides = {}) {
  const document = { handlers: {}, activeElement: null };
  const elements = Object.fromEntries(ids.map((id) => [id, new Element(id === 'search' ? 'input' : 'div', document)]));
  document.getElementById = (id) => elements[id];
  document.createElement = (tag) => new Element(tag, document);
  document.addEventListener = (name, fn) => { document.handlers[name] = fn; };
  let state = ready();
  let closed = 0;
  const applied = [];
  const listeners = {};
  const nook = {
    plugin: { id: 'windows' },
    on: (name, fn) => { listeners[name] = fn; },
    settings: { get: async () => ({ closeAfterAction: false }) },
    notch: { close: async () => { closed++; listeners.close?.(); } },
    windows: {
      state: async () => state,
      apply: async (id) => { applied.push(id); return state; },
      openPrivacy: async () => {},
      openSettings: async () => {},
      ...overrides
    }
  };
  vm.runInNewContext(code, { document, nook, window: { nook } }, { filename: source });
  await tick();
  const key = (name, mods = {}) => {
    const event = { key: name, preventDefault() { this.prevented = true; }, ...mods };
    document.handlers.keydown(event);
    // Model the browser's native Enter activation for real buttons.
    if (name === 'Enter' && !event.prevented && document.activeElement?.tagName === 'button' && !document.activeElement.disabled) document.activeElement.fire('click');
    return event;
  };
  return { elements, document, nook, applied, key, listeners, get closed() { return closed; }, setState(next) { state = next; }, buttons: () => elements.actions.querySelectorAll('button') };
}

(async () => {
  const app = await setup();
  assert.equal(app.buttons().length, 23);
  assert.equal(app.elements.loading.hidden, true);
  assert.equal(app.elements.actions.hidden, false);
  assert.match(app.elements.target.textContent, /Editor/);
  assert.equal(app.buttons()[0].dataset.action, 'previousDisplay');
  app.listeners.open('windows');
  await tick();
  assert.equal(app.document.activeElement, app.elements.search);
  app.key('ArrowDown');
  assert.equal(app.document.activeElement.dataset.action, 'previousDisplay');
  app.key('ArrowRight');
  assert.equal(app.document.activeElement.dataset.action, 'nextDisplay');
  app.key('ArrowDown');
  assert.equal(app.document.activeElement.dataset.action, 'nextDesktop');
  app.listeners.windows(null);
  await tick();
  assert.equal(app.document.activeElement, app.buttons().find((button) => button.dataset.action === 'nextDesktop'), 'Refreshing shortcuts retains focus on the new DOM button');
  app.key('Enter');
  await tick();
  assert.deepEqual(app.applied, ['nextDesktop']);
  assert.equal(app.closed, 0);

  app.elements.search.value = 'half';
  app.elements.search.fire('input');
  assert.equal(app.buttons().length, 4);
  app.elements.search.focus();
  app.key('Enter', { metaKey: true });
  await tick();
  assert.equal(app.applied.at(-1), 'leftHalf');
  app.elements.search.value = '<nothing matches>';
  app.elements.search.fire('input');
  assert.equal(app.buttons().length, 0);
  assert.equal(app.elements.emptyTitle.textContent, 'No matching actions');
  app.key('Enter');
  await tick();
  assert.equal(app.applied.length, 2);
  app.elements.search.value = '';
  app.elements.search.fire('input');
  app.setState({ ...ready(), busy: true });
  app.listeners.windows(null);
  await tick();
  assert.ok(app.buttons().every((button) => button.disabled), 'Another notch can make actions temporarily busy');
  app.setState(ready());
  app.listeners.windows(null);
  await tick();
  assert.ok(app.buttons().every((button) => !button.disabled), 'Completion in another notch re-enables actions');
  app.key('Escape');
  await tick();
  assert.equal(app.closed, 1);

  let resolveMove;
  const pending = await setup({ apply: () => new Promise((resolve) => { resolveMove = resolve; }) });
  pending.elements.search.focus();
  pending.key('Enter');
  pending.key('Enter');
  assert.equal(pending.elements.search.disabled, true);
  assert.ok(pending.buttons().every((button) => button.disabled));
  resolveMove(ready());
  await tick();
  assert.equal(pending.elements.search.disabled, false);

  let resolveRefresh;
  const stale = await setup();
  stale.nook.windows.state = () => new Promise((resolve) => { resolveRefresh = resolve; });
  stale.listeners.show('windows');
  stale.elements.search.focus();
  stale.key('Enter');
  await tick();
  resolveRefresh({ ...ready(), target: 'Stale target' });
  await tick();
  assert.match(stale.elements.target.textContent, /Editor/, 'A state call started before an action cannot replace the result');

  const failure = await setup({ apply: async () => { throw new Error('No next desktop'); } });
  failure.elements.search.focus();
  failure.key('Enter');
  await tick();
  assert.equal(failure.elements.error.hidden, false);
  assert.equal(failure.elements.error.textContent, 'No next desktop');
  assert.equal(failure.closed, 0);
  assert.ok(failure.buttons().every((button) => !button.disabled));

  const noWindow = await setup({ state: async () => ({ ...ready(), target: null, message: 'Focus a window' }) });
  assert.equal(noWindow.elements.emptyTitle.textContent, 'No window selected');
  assert.equal(noWindow.elements.actions.hidden, true);
  const permission = await setup({ state: async () => ({ ...ready(), trusted: false, target: null }) });
  assert.equal(permission.elements.emptyTitle.textContent, 'Accessibility needed');
  assert.equal(permission.elements.privacy.hidden, false);
  const unavailable = await setup({ state: async () => { throw new Error('Update required'); } });
  assert.equal(unavailable.elements.loading.hidden, true);
  assert.equal(unavailable.elements.emptyTitle.textContent, 'Actions unavailable');
  assert.equal(unavailable.elements.error.textContent, 'Update required');

  const recentError = await setup({ state: async () => ({ ...ready(), lastError: 'Title bar unavailable' }) });
  assert.equal(recentError.elements.error.textContent, 'Title bar unavailable');
  app.elements.search.value = '';
  app.elements.search.fire('input');
  app.listeners.settings({ closeAfterAction: true });
  app.elements.search.focus();
  app.key('Enter');
  await tick();
  assert.equal(app.closed, 2);
  console.log('Passed mocked plugin states, search, navigation, Enter/⌘Enter/Esc, serialization, preferences and errors');
})().catch((err) => { console.error(err); process.exitCode = 1; }).finally(() => { fs.rmSync(folder, { recursive: true, force: true }); });
