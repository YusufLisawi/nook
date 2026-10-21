// Feature namespace is local to this package; Nook exposes only the v2 transport.
const featureAPI = new Proxy({}, {get: (_, method) => (...args) => nook.native.call("windows." + method, {args})});
/* Window targets are captured natively before the notch opens, never by this web view. */
(() => {
  const $ = (id) => document.getElementById(id);
  let state = null;
  let applying = false;
  let selected = '';
  let settings = { closeAfterAction: true };
  let request = 0;
  let visible = true; // the host first creates this view when the tab is shown

  function error(message = '') {
    $('error').textContent = message;
    $('error').hidden = !message;
  }

  function buttons() { return Array.from($('actions').querySelectorAll('button')); }

  function choose(button, focus = false) {
    if (!button) return;
    selected = button.dataset.action;
    for (const item of buttons()) item.classList.toggle('nk-selected', item === button);
    if (focus) { button.focus(); button.scrollIntoView({ block: 'nearest' }); }
  }

  function render() {
    const focusedAction = document.activeElement?.dataset?.action;
    $('loading').hidden = true;
    const available = state?.trusted && state?.target;
    const query = $('search').value.trim().toLowerCase();
    const actions = (state?.actions || []).filter((action) =>
      `${action.title} ${action.group} ${action.shortcut}`.toLowerCase().includes(query));
    $('target').textContent = state?.target ? `Selected window · ${state.target}` : 'No window selected';
    $('search').disabled = applying;
    $('actions').hidden = !available || !actions.length;
    $('empty').hidden = !!available && !!actions.length;
    $('privacy').hidden = state?.trusted !== false;
    $('emptyTitle').textContent = !state?.trusted ? 'Accessibility needed' : available ? 'No matching actions' : 'No window selected';
    $('emptyMessage').textContent = available ? 'Try “display”, “desktop” or “half”.' : (state?.message || 'Focus a window, then reopen the notch.');
    $('hint').textContent = applying ? 'Applying…' : 'Arrows to choose · Enter to apply · Esc to close';
    const children = [];
    let group = '';
    for (const action of available ? actions : []) {
      if (group !== action.group) {
        group = action.group;
        children.push(Object.assign(document.createElement('div'), { className: 'group nk-label', textContent: group }));
      }
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'action nk-item';
      button.dataset.action = action.id;
      button.disabled = applying || !!state?.busy;
      button.title = action.conflict ? `Shortcut unavailable: ${action.conflict}. This button still works.` : action.title;
      button.append(Object.assign(document.createElement('span'), { className: 'nk-fill nk-ellipsis', textContent: action.title }));
      const shortcut = Object.assign(document.createElement('kbd'), { textContent: action.shortcut || '—' });
      if (action.conflict) shortcut.className = 'conflict';
      button.append(shortcut);
      button.addEventListener('focus', () => choose(button));
      button.addEventListener('click', () => { choose(button); apply(action.id); });
      children.push(button);
    }
    $('actions').replaceChildren(...children);
    const items = buttons();
    choose(items.find((button) => button.dataset.action === selected) || items[0]);
    if (focusedAction && visible && !applying) {
      const replacement = items.find((button) => button.dataset.action === focusedAction);
      if (replacement && !replacement.disabled) choose(replacement, true);
      else $('search').focus();
    }
  }

  async function refresh(focus = false) {
    if (applying) return;
    const current = ++request;
    try {
      const next = await featureAPI.state();
      if (current !== request) return;
      state = next;
      error(next.lastError || '');
      render();
      if (focus && visible && !applying) $('search').focus();
    } catch (err) {
      if (current !== request) return;
      $('loading').hidden = true;
      $('empty').hidden = false;
      $('actions').hidden = true;
      $('emptyTitle').textContent = 'Actions unavailable';
      $('emptyMessage').textContent = 'Retry, or update Nook to use window management.';
      error(err.message || String(err));
    }
  }

  async function close() {
    try { await nook.notch.close(); } catch (err) { error(err.message || String(err)); }
  }

  async function apply(id) {
    if (applying || state?.busy || !id || !state?.target) return;
    applying = true;
    ++request; // discard state replies that started before this action
    error();
    render();
    try {
      state = await featureAPI.apply(id);
      if (settings.closeAfterAction) await close();
      else $('hint').textContent = 'Applied';
    } catch (err) {
      error(err.message || String(err));
    } finally {
      applying = false;
      render();
      if (visible) $('search').focus();
    }
  }

  $('search').addEventListener('input', render);
  $('retry').addEventListener('click', () => refresh(true));
  $('settings').addEventListener('click', async () => {
    try { await featureAPI.openSettings(); } catch (err) { error(err.message || String(err)); }
  });
  $('privacy').addEventListener('click', async () => {
    try { await featureAPI.openPrivacy(); } catch (err) { error(err.message || String(err)); }
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') { event.preventDefault(); close(); return; }
    if (applying || event.isComposing) return;
    const items = buttons();
    const index = Math.max(0, items.findIndex((button) => button.dataset.action === selected));
    const inSearch = document.activeElement === $('search');
    if (event.key === 'Enter' && (inSearch || event.metaKey)) {
      event.preventDefault();
      apply(items[index]?.dataset.action);
      return;
    }
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    let next;
    if (event.key === 'ArrowDown') next = inSearch ? index : Math.min(items.length - 1, index + 2);
    else if (event.key === 'ArrowUp') next = inSearch ? items.length - 1 : Math.max(0, index - 2);
    else if (!inSearch && event.key === 'ArrowRight') next = Math.min(items.length - 1, index + 1);
    else if (!inSearch && event.key === 'ArrowLeft') next = Math.max(0, index - 1);
    else if (!inSearch && event.key === 'Home') next = 0;
    else if (!inSearch && event.key === 'End') next = items.length - 1;
    if (next !== undefined && items[next]) { event.preventDefault(); choose(items[next], true); }
  });

  nook.native.on('ready', () => { if (visible) refresh(); });
  nook.on('open', (tab) => { visible = tab === nook.plugin.id; if (visible) refresh(true); });
  nook.on('show', (tab) => { visible = tab === nook.plugin.id; if (visible) refresh(true); });
  nook.on('close', () => { visible = false; });
  nook.native.on('windows', () => { if (visible && !applying) refresh(); });
  nook.native.on('windowsError', (message) => error(message));
  nook.on('settings', (next) => { settings = { ...settings, ...next }; });
  (async () => {
    try { settings = { ...settings, ...await nook.settings.get() }; }
    catch (err) { error(`Couldn't load preferences: ${err.message || err}`); }
    await refresh(true);
  })();
})();
