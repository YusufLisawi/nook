/* global nook, FileSearchModel */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const model = window.FileSearchModel;
  const state = { clientID: window.crypto?.randomUUID?.() || `files-${Date.now()}-${Math.random()}`, requestID: 0,
    results: [], selected: -1, previewID: 0, previewKey: '', active: true, composing: false, receivedRequestID: 0,
    settings: { showPreview: true, resultLimit: 60 }, menuIndex: 0, menuActions: [] };
  let previewTimer, statusTimer, keepAliveTimer;
  const hints = '↑↓ Select · ↵ Open · ⌘↵ Reveal · Space Preview';
  const scopeNames = { home: 'Home', Developer: 'Developer', Downloads: 'Downloads', all: 'All indexed locations' };
  function error(message) { $('error-text').textContent = String(message?.message || message); $('error').hidden = false; }
  function status(message) {
    clearTimeout(statusTimer); $('status').textContent = message;
    statusTimer = setTimeout(() => { $('status').textContent = hints; }, 2400);
  }
  function current() { return state.results[state.selected]; }
  function focusSearch() { $('search').focus(); }
  function hideMenu(focus = false) {
    $('menu').hidden = true; $('actions').setAttribute('aria-expanded', 'false');
    if (focus) focusSearch();
  }
  function applySettings(settings) {
    state.settings = { ...state.settings, ...settings };
    $('workspace').classList.toggle('no-preview', !state.settings.showPreview);
    $('preview').hidden = !state.settings.showPreview;
    state.previewKey = ''; schedulePreview();
  }
  function resetPreview() {
    state.previewID++; clearTimeout(previewTimer); state.previewKey = '';
    $('preview-loading').hidden = true; $('preview-content').hidden = true; $('preview-error').hidden = true;
    $('preview-empty').hidden = false; $('thumbnail').removeAttribute('src'); $('text-preview').textContent = '';
  }
  function schedulePreview() {
    const file = current();
    if (!state.active || !file || !state.settings.showPreview) { resetPreview(); return; }
    const key = JSON.stringify([file.path, file.modified, file.size]);
    if (key === state.previewKey) return;
    clearTimeout(previewTimer);
    state.previewKey = key;
    const id = ++state.previewID;
    $('preview-empty').hidden = true; $('preview-content').hidden = true; $('preview-error').hidden = true;
    $('preview-loading').hidden = false;
    // Skip thumbnail work for rows crossed quickly with the arrow keys.
    previewTimer = setTimeout(async () => {
      try {
        const preview = await nook.files.preview(file.path);
        if (id !== state.previewID || !state.active) return;
        $('preview-loading').hidden = true; $('preview-content').hidden = false;
        const hasText = typeof preview.text === 'string';
        $('text-preview').hidden = !hasText;
        $('text-preview').textContent = hasText ? preview.text : '';
        $('text-preview').scrollTop = 0;
        const image = typeof preview.thumbnail === 'string' && preview.thumbnail.startsWith('data:image/');
        $('preview-visual').hidden = !image;
        if (image) $('thumbnail').src = preview.thumbnail; else $('thumbnail').removeAttribute('src');
        $('preview-notice').hidden = !preview.notice && !preview.truncated;
        $('preview-notice').textContent = preview.truncated ? 'First 20 KB · Space for Quick Look' : preview.notice || '';
        $('preview-name').textContent = preview.name || file.name;
        $('meta-kind').textContent = preview.kind || file.kind;
        $('meta-size').textContent = file.category === 'folder' ? '—' : model.size(preview.size);
        $('meta-modified').textContent = preview.modified ? new Date(preview.modified * 1000).toLocaleString() : '—';
        $('meta-path').textContent = preview.path || file.path;
      } catch (err) {
        if (id !== state.previewID || !state.active) return;
        $('preview-loading').hidden = true; $('preview-error').hidden = false;
        $('preview-error').textContent = `Preview unavailable: ${err.message || err}. Press Space for Quick Look.`;
      }
    }, 70);
  }
  function select(index, scroll = true) {
    state.selected = state.results.length ? Math.max(0, Math.min(state.results.length - 1, index)) : -1;
    [...$('results').children].forEach((row, i) => {
      const selected = i === state.selected;
      row.classList.toggle('nk-selected', selected); row.setAttribute('aria-selected', String(selected));
      if (selected && scroll) row.scrollIntoView({ block: 'nearest' });
    });
    if (current()) $('search').setAttribute('aria-activedescendant', `file-${state.selected}`);
    else $('search').removeAttribute('aria-activedescendant');
    $('actions').disabled = !current(); schedulePreview();
  }
  function render(results) {
    const path = current()?.path;
    state.results = results;
    const fragment = document.createDocumentFragment();
    results.forEach((file, index) => {
      const row = document.createElement('div');
      row.className = 'nk-item file-row'; row.id = `file-${index}`;
      row.setAttribute('role', 'option'); row.setAttribute('aria-selected', 'false');
      const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      icon.classList.add('icon'); icon.setAttribute('aria-hidden', 'true');
      const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
      use.setAttribute('href', `#i-${['folder', 'app', 'image', 'code'].includes(file.category) ? file.category : 'file'}`); icon.append(use);
      const text = document.createElement('div'); text.className = 'nk-fill';
      const name = document.createElement('div'); name.className = 'file-name nk-ellipsis';
      for (const segment of model.segments(file.name, $('search').value)) {
        const span = document.createElement(segment.match ? 'mark' : 'span'); span.textContent = segment.text; name.append(span);
      }
      const parent = document.createElement('div'); parent.className = 'file-path nk-muted nk-ellipsis';
      parent.textContent = model.parent(file.path); parent.title = file.path;
      text.append(name, parent); row.append(icon, text);
      row.addEventListener('click', () => { select(index); focusSearch(); });
      row.addEventListener('dblclick', () => { select(index); void action('open'); });
      fragment.append(row);
    });
    $('results').replaceChildren(fragment);
    let index = results.findIndex(file => file.path === path);
    if (index < 0) index = results.length ? 0 : -1;
    select(index, false);
    $('empty').hidden = results.length > 0;
  }
  function receive(event) {
    if (!state.active || !model.accepts(state, event)) return;
    state.receivedRequestID = state.requestID;
    if (event.error) { error(event.error); $('spinner').hidden = true; return; }
    const results = Array.isArray(event.results) ? event.results : [];
    render(results); $('spinner').hidden = !event.gathering;
    $('count').textContent = `${results.length}${event.truncated || results.length >= Number(state.settings.resultLimit) ? '+' : ''} files`;
    $('empty-title').textContent = event.gathering ? 'Searching Spotlight…' : $('search').value.trim() ? 'No matching files' : 'No recent files';
    $('empty-detail').textContent = event.gathering ? 'Results appear as they arrive.' : 'Try another name or scope. Only Spotlight-indexed files appear.';
    if (!$('scope').value && scopeNames[event.scope]) $('scope').options[0].textContent = `Default · ${scopeNames[event.scope]}`;
  }
  async function search() {
    if (!state.active || state.composing) return;
    const requestID = ++state.requestID;
    hideMenu(); $('error').hidden = true; $('spinner').hidden = false; $('count').textContent = 'Searching…';
    render([]); resetPreview(); $('empty').hidden = false;
    $('empty-title').textContent = 'Searching Spotlight…'; $('empty-detail').textContent = 'Results appear as they arrive.';
    try {
      if (!nook.files?.search) throw new Error('This tab needs a version of Nook with File Search support.');
      const options = { clientID: state.clientID, requestID: String(requestID), kind: $('kind').value,
        limit: Math.min(100, Math.max(10, Number(state.settings.resultLimit) || 60)) };
      if ($('scope').value) options.scope = $('scope').value;
      const response = await nook.files.search($('search').value, options);
      // A progress event may arrive before the initial reply; don't replace it with cached candidates.
      if (requestID === state.requestID && state.receivedRequestID !== requestID) receive(response);
    } catch (err) {
      if (requestID !== state.requestID || !state.active) return;
      $('spinner').hidden = true; $('count').textContent = ''; error(err);
      $('empty-title').textContent = 'Search unavailable'; $('empty-detail').textContent = 'Retry, or check Spotlight Search Privacy in System Settings.';
    }
  }
  async function action(name, appPath) {
    const file = current(); if (!file) return;
    hideMenu(true);
    try {
      if (name === 'openWith' && !appPath) {
        const path = file.path, requestID = state.requestID;
        const apps = await nook.files.openWith(path);
        if (current()?.path !== path || requestID !== state.requestID || !state.active) return;
        if (!apps.length) { status('No applications available for this file'); return; }
        showMenu(apps.map(app => ({ title: app.name, hint: '', run: () => action('openWith', app.path) })));
        return;
      }
      await nook.files[name](file.path, ...(appPath ? [appPath] : []));
      if (name === 'copyPath') status('Path copied · ⌘⇧C copies the file');
      if (name === 'copyFile') status('File copied · paste in Finder');
    } catch (err) { error(err); }
  }
  function showMenu(actions) {
    state.menuActions = actions || [
      { title: 'Open', hint: '↵', run: () => action('open') },
      { title: 'Reveal in Finder', hint: '⌘↵', run: () => action('reveal') },
      { title: 'Quick Look', hint: 'Space', run: () => action('quickLook') },
      { title: 'Copy Path', hint: '⌘C', run: () => action('copyPath') },
      { title: 'Copy File', hint: '⌘⇧C', run: () => action('copyFile') },
      { title: 'Open With…', hint: '', run: () => action('openWith') }
    ];
    const buttons = state.menuActions.map(item => {
      const button = document.createElement('button'); button.type = 'button'; button.className = 'nk-item menu-action'; button.setAttribute('role', 'menuitem');
      const title = document.createElement('span'); title.textContent = item.title;
      const hint = document.createElement('kbd'); hint.textContent = item.hint;
      button.append(title, hint);
      button.addEventListener('focus', () => { state.menuIndex = state.menuActions.indexOf(item); });
      button.addEventListener('click', () => void item.run()); return button;
    });
    $('menu').replaceChildren(...buttons); $('menu').hidden = false; $('actions').setAttribute('aria-expanded', 'true');
    state.menuIndex = 0; buttons[0]?.focus();
  }
  function keydown(event) {
    if (event.isComposing || state.composing) return;
    const command = event.metaKey || event.ctrlKey;
    if (!$('menu').hidden) {
      if (event.key === 'Escape' || command && event.key.toLowerCase() === 'k') { event.preventDefault(); event.stopPropagation(); hideMenu(true); return; }
      if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
        event.preventDefault(); const length = state.menuActions.length;
        state.menuIndex = event.key === 'Home' ? 0 : event.key === 'End' ? length - 1 : (state.menuIndex + (event.key === 'ArrowDown' ? 1 : length - 1)) % length;
        $('menu').children[state.menuIndex]?.focus(); return;
      }
      if (event.key === 'Enter') { event.preventDefault(); void state.menuActions[state.menuIndex]?.run(); return; }
      if (event.key === 'Tab') { event.preventDefault(); hideMenu(); $('actions').focus(); }
      return;
    }
    if (command && event.key.toLowerCase() === 'k' && current()) { event.preventDefault(); showMenu(); return; }
    if (command && event.key.toLowerCase() === 'c' && current()) { event.preventDefault(); void action(event.shiftKey ? 'copyFile' : 'copyPath'); return; }
    // Tab follows the normal focus order: search → scope → kind → results → preview → actions.
    // The native selects keep their arrow keys; Tab never traps focus.
    if (event.target.tagName === 'SELECT' || event.target.id === 'text-preview' || event.target.closest('button')) return;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault(); select(state.selected + (event.key === 'ArrowDown' ? 1 : -1)); return;
    }
    if (event.key === 'Enter' && current()) { event.preventDefault(); void action(command ? 'reveal' : 'open'); return; }
    if (event.key === ' ' && current() && !command && !event.altKey) {
      // Shift-Space inserts a space for names containing words; plain Space invokes Quick Look.
      if (event.shiftKey && event.target === $('search')) return;
      event.preventDefault(); void action('quickLook'); return;
    }
    if (event.key === 'Escape') {
      event.preventDefault();
      try { Promise.resolve(nook.notch.close()).catch(error); } catch (err) { error(err); }
    }
  }
  document.addEventListener('keydown', keydown);
  document.addEventListener('pointerdown', event => { if (!$('menu').contains(event.target) && !$('actions').contains(event.target)) hideMenu(); });
  $('search').addEventListener('input', () => void search());
  $('search').addEventListener('compositionstart', () => { state.composing = true; });
  $('search').addEventListener('compositionend', () => { state.composing = false; void search(); });
  $('scope').addEventListener('change', () => void search()); $('kind').addEventListener('change', () => void search());
  $('retry').addEventListener('click', () => void search());
  $('actions').addEventListener('click', () => { if ($('menu').hidden) showMenu(); else hideMenu(true); });
  nook.on('files', receive);
  nook.on('filesShortcut', name => { if (state.active && ['copyPath', 'copyFile'].includes(name)) void action(name); });
  nook.on('filesSettings', () => { if (state.active) void search(); });
  nook.on('settings', settings => { applySettings(settings); if (state.active) void search(); });
  function deactivate() {
    state.active = false; state.requestID++; hideMenu(); resetPreview(); $('spinner').hidden = true;
    clearInterval(keepAliveTimer); keepAliveTimer = null;
    try { Promise.resolve(nook.files?.cancel(state.clientID)).catch(error); } catch (err) { error(err); }
  }
  function keepAlive() {
    if (keepAliveTimer) return;
    keepAliveTimer = setInterval(async () => {
      if (!state.active) return;
      try {
        const alive = await nook.files?.keepAlive(state.clientID);
        if (alive === false && state.active) await search(); // resume after a long sleep or app nap
      } catch (err) { error(err); }
    }, 30000);
  }
  function shown(tabID) {
    // Nook broadcasts tab changes to all loaded web views, including hidden tabs.
    if (tabID && tabID !== nook.plugin.id) { deactivate(); return; }
    state.active = true; keepAlive(); focusSearch(); void search();
  }
  nook.on('show', shown);
  nook.on('open', shown);
  nook.on('close', deactivate);
  (async () => {
    try { applySettings(await nook.settings.get()); } catch (err) { error(err); }
    if (state.active) { keepAlive(); focusSearch(); await search(); }
  })();
})();
