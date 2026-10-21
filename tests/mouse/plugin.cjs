const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const plugin = process.argv[2];
const html = fs.readFileSync(path.join(plugin, 'index.html'), 'utf8');
const source = fs.readFileSync(path.join(plugin, 'main.js'), 'utf8');
const tick = () => new Promise(resolve => setTimeout(resolve, 0));

async function setup(failFirst = false) {
  const dom = new JSDOM(html, { runScripts: 'outside-only', url: 'https://mouse.test/' });
  const w = dom.window, events = {}, calls = [];
  let failed = failFirst;
  let state = {
    config: { enabled: false, smoothness: 'regular', speed: 1, acceleration: 0.5, reverse: false,
      filterChatter: false, horizontalModifier: 'shift', preciseModifier: 'none', quickModifier: 'none', buttons: {} },
    trusted: true, running: false, learning: false, error: null,
    actions: [{ id: 'none', label: 'Default' }, { id: 'copy', label: 'Copy' }, { id: 'back', label: 'Back' }],
  };
  w.nook = { on(event, fn) { events[event] = fn; }, mouse: new Proxy({}, {
    get(_, fn) { return async (...args) => {
      calls.push([fn, ...args]);
      if (failed) { failed = false; throw new Error('Engine disconnected'); }
      if (fn === 'set') Object.assign(state.config, args[0]);
      if (fn === 'learn') state.learning = args[0];
      if (fn === 'setButton') state.config.buttons[args[0]] = { click: 'none', hold: 'none', drag: 'none', ...state.config.buttons[args[0]], ...args[1] };
      if (fn === 'removeButton') delete state.config.buttons[args[0]];
      return JSON.parse(JSON.stringify(state));
    }; }
  }) };
  w.eval(source);
  await tick();
  return { w, events, state, calls, $: id => w.document.getElementById(id), close: () => w.close() };
}

(async () => {
  const x = await setup(true);
  assert.match(x.$('error').textContent, /Engine disconnected/);
  assert.equal(x.$('enabled').disabled, true);
  x.$('error').querySelector('button').click(); await tick();
  assert.equal(x.$('error').hidden, true);
  assert.equal(x.$('enabled').disabled, false);
  assert.equal(x.$('status').lastElementChild.textContent, 'Off');
  assert.match(x.$('rules').textContent, /No buttons yet/);
  assert.equal(x.$('scroll').querySelector('[data-key="filterChatter"]').checked, false);
  for (const el of x.w.document.querySelectorAll('select,input')) {
    assert.ok(el.getAttribute('aria-label'), 'Every form control has an accessible name');
  }
  const chatter = x.$('scroll').querySelector('[data-key="filterChatter"]');
  chatter.checked = true; chatter.dispatchEvent(new x.w.Event('change')); await tick();
  assert.equal(x.state.config.filterChatter, true);
  const enabled = x.$('enabled');
  enabled.checked = true; enabled.dispatchEvent(new x.w.Event('change')); await tick();
  assert.equal(x.state.config.enabled, true);
  x.state.error = "Couldn't start the mouse event tap. Check Accessibility; Nook will retry automatically.";
  x.events.mouse({}); await tick();
  assert.equal(x.$('status').lastElementChild.textContent, 'Unavailable');
  assert.match(x.$('error').textContent, /retry automatically/);
  x.state.error = null; x.state.running = true; x.events.mouse({}); await tick();
  assert.equal(x.$('error').hidden, true);
  assert.equal(x.$('status').lastElementChild.textContent, 'Active');
  x.state.trusted = false; x.events.mouse({}); await tick();
  assert.match(x.$('error').textContent, /Allow Nook in Accessibility/);
  x.$('error').querySelector('button').click(); await tick();
  assert.ok(x.calls.some(([fn]) => fn === 'openPrivacy'));
  x.state.trusted = true;
  x.$('view').querySelector('[data-view="buttons"]').click();
  assert.equal(x.$('scroll').hidden, true); assert.equal(x.$('buttons').hidden, false);
  x.$('learn').dispatchEvent(new x.w.KeyboardEvent('keydown', { key: 'Enter', metaKey: true, bubbles: true, cancelable: true })); await tick();
  assert.equal(x.state.learning, true);
  x.state.learning = false;
  x.events.mouse({ button: 3 }); await tick();
  assert.ok(x.state.config.buttons['3']);
  let select = x.$('rules').querySelector('[data-rule="click"]');
  select.focus(); select.value = 'copy'; select.dispatchEvent(new x.w.Event('change')); await tick();
  assert.equal(x.state.config.buttons['3'].click, 'copy');
  assert.equal(x.w.document.activeElement.dataset.rule, 'click', 'Focus survives rule repaint');
  assert.equal(x.w.document.activeElement.dataset.button, '3');
  x.$('rules').querySelector('[data-rule="remove"]').click(); await tick();
  assert.match(x.$('rules').textContent, /No buttons yet/);
  x.state.learning = true; x.events.mouse({}); await tick(); x.events.close(); await tick();
  assert.equal(x.state.learning, false, 'Closing cancels learning');
  assert.ok(x.$('view').classList.contains('nk-roving'));
  assert.equal(x.$('view').dataset.nkOrientation, 'horizontal');
  x.close();
  console.log('PASS: Mouse plugin mocked window.nook loading/error/retry/permission/recovery, chatter setting, learn/remap/remove, focus and keyboard actions (under /tmp)');
})().catch(error => { console.error(error); process.exitCode = 1; });
