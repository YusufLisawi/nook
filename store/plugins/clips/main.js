// Feature namespace is local to this package; Nook exposes only the v2 transport.
const featureAPI = new Proxy({}, {get: (_, method) => async (...args) => {
  if (!['history', 'screenshots'].includes(method)) return nook.native.call('clips.' + method, {args});
  let offset = 0, rows = [];
  do {
    const page = await nook.native.call('clips.' + method + 'Page', {args: [args[0] || '', {offset}]});
    if (!page || !Array.isArray(page.items) || page.next !== null && (!Number.isInteger(page.next) || page.next <= offset)) throw new Error('Invalid history page. Retry.');
    rows.push(...page.items); offset = page.next;
  } while (offset !== null && rows.length < 20000);
  return rows;
}});
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id), D = globalThis.ClipsUI;
  const icons = {
    text: '<path d="M4 5h16M4 10h16M4 15h12M4 20h8"/>',
    link: '<path d="m10 14 4-4m-6 6-1 1a4 4 0 0 1-6-6l4-4a4 4 0 0 1 6 0m2 2 1-1a4 4 0 0 1 6 6l-4 4a4 4 0 0 1-6 0"/>',
    image: '<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8" cy="8" r="1"/><path d="m3 17 5-5 4 4 4-7 5 8"/>',
    files: '<path d="M5 3h9l5 5v13H5zM14 3v6h5"/>',
    color: '<circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 0 0 18z"/>',
    recording: '<rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-3v10l-5-3"/>'
  };
  let view = 'clipboard', items = [], selected = null, request = 0, loaded = false, busy = false;
  let searchTimer, confirmationID = null, status = {}, feedbackTimer;
  const thumbnails = new Map(), pendingThumbnails = new Set();
  const observer = typeof IntersectionObserver === 'function' ? new IntersectionObserver((entries) => {
    for (const entry of entries) if (entry.isIntersecting) { loadThumbnail(entry.target); observer.unobserve(entry.target); }
  }, { root: $('content') }) : null;

  function error(message) { $('error-text').textContent = message || ''; $('error').hidden = !message; }
  function feedback(message) {
    clearTimeout(feedbackTimer);
    $('feedback').textContent = message || 'Copy to Clipboard ↩ · Paste ⌘↩';
    if (message) feedbackTimer = setTimeout(() => feedback(), 2200);
  }
  function current() { return items.find((item) => item.id === selected); }
  function select(id, scroll = false) {
    selected = id;
    let activeID = '';
    for (const row of $('content').children) {
      const active = row.dataset.id === id;
      row.classList.toggle('nk-selected', active);
      row.setAttribute('aria-selected', String(active));
      row.tabIndex = -1;
      if (active) activeID = row.id;
      if (active && scroll) row.scrollIntoView({ block: 'nearest' });
    }
    $('content').setAttribute('aria-activedescendant', activeID);
    $('actions').disabled = !current() || busy;
  }
  async function loadThumbnail(row) {
    const id = row.dataset.id, key = row.dataset.thumbnailKey, image = row.querySelector('img');
    if (!image || pendingThumbnails.has(key)) return;
    if (thumbnails.has(key)) { image.src = thumbnails.get(key); image.hidden = false; return; }
    pendingThumbnails.add(key);
    try {
      const src = await featureAPI.thumbnail(id);
      if (typeof src === 'string' && src.startsWith('data:image/jpeg;base64,')) {
        if (thumbnails.size >= 100) thumbnails.delete(thumbnails.keys().next().value);
        thumbnails.set(key, src);
        for (const candidate of $('content').children) if (candidate.dataset.id === id && candidate.dataset.thumbnailKey === key) {
          const target = candidate.querySelector('img');
          if (target) { target.src = src; target.hidden = false; }
        }
      }
    } catch { image.alt = 'Preview unavailable'; }
    finally { pendingThumbnails.delete(key); }
  }
  function render() {
    observer?.disconnect();
    $('content').replaceChildren();
    $('content').classList.toggle('grid', view === 'screenshots');
    $('content').setAttribute('aria-label', view === 'clipboard' ? 'Clipboard history' : 'Screenshots and recordings');
    $('count').textContent = loaded ? `${items.length} ${items.length === 1 ? 'item' : 'items'}` : '';
    $('loading').hidden = loaded;
    $('empty').hidden = !loaded || items.length > 0;
    $('content').hidden = !loaded || !items.length;
    const searching = !!$('search').value.trim();
    $('empty-title').textContent = searching ? 'No matches' : view === 'clipboard' ? 'Nothing copied yet' : 'No screenshots yet';
    $('empty-detail').textContent = searching ? 'Try another search or use date:today, name: or text:.' : view === 'clipboard' ? 'Copy text, an image, a color, or a file to save it here.' : 'Screenshots and recordings from your capture folder appear here.';
    $('notice').textContent = view === 'clipboard' && status.enabled === false ? 'Clipboard capture is paused. Enable it in Settings → Clipboard.' : view === 'screenshots' && status.indexing ? 'Scanning your screenshot folder…' : '';
    $('notice').hidden = !$('notice').textContent;
    for (const item of items) {
      const row = document.createElement('div');
      row.className = `nk-item clip${view === 'screenshots' ? ' tile' : ''}`;
      row.id = `clip-option-${item.id}`;
      row.dataset.id = item.id; row.setAttribute('role', 'option');
      row.dataset.thumbnailKey = `${item.id}|${item.modifiedAt || 0}`;
      row.setAttribute('aria-label', `${item.pinned ? 'Pinned, ' : ''}${item.name || item.kind}, ${D.captions(item.date)}`);
      const preview = ['image', 'screenshot', 'recording'].includes(item.kind);
      row.innerHTML = `<div class="clip-icon"><svg viewBox="0 0 24 24" aria-hidden="true">${icons[item.kind] || icons.image}</svg>${preview ? '<img alt="" hidden>' : ''}</div><div class="clip-copy"><span class="clip-title nk-ellipsis"></span><span class="clip-meta"><span class="nk-ellipsis"></span><span class="pin"></span></span></div>`;
      row.querySelector('.clip-title').textContent = item.kind === 'image' ? 'Image' : item.name || item.text || item.kind;
      row.querySelector('.clip-meta > span').textContent = view === 'screenshots' ? D.captions(item.date) : [item.kind === 'files' ? 'File' : item.kind, item.source, D.captions(item.date)].filter(Boolean).join(' · ');
      row.querySelector('.pin').textContent = item.pinned ? 'Pinned' : '';
      if (item.kind === 'color' && /^#[0-9a-f]{3,8}$/i.test((item.text || '').trim())) row.querySelector('.clip-icon').style.backgroundColor = item.text.trim();
      row.onclick = () => { closeMenu(); cancelDelete(); select(item.id); $('content').focus({ preventScroll: true }); };
      row.ondblclick = () => run('copy', item.id);
      row.onfocus = () => select(item.id);
      row.oncontextmenu = (event) => { event.preventDefault(); select(item.id); showMenu(); };
      $('content').append(row);
      if (preview) { if (observer) observer.observe(row); else loadThumbnail(row); }
    }
    if (!items.some((item) => item.id === selected)) selected = items[0]?.id || null;
    select(selected);
  }
  async function refresh() {
    const revision = ++request, source = view, query = $('search').value;
    try {
      if (!nook.native?.call) throw new Error('Clips needs the native helper. Re-enable the plugin and retry.');
      const [list, nextStatus] = await Promise.all([source === 'clipboard' ? featureAPI.history(query) : featureAPI.screenshots(query), featureAPI.status()]);
      if (revision !== request) return;
      items = D.normalize(list); status = nextStatus || {};
      loaded = !(source === 'clipboard' ? status.clipboardLoading : status.screenshotsLoading) || !!items.length || !!(source === 'clipboard' ? status.clipboardError : status.screenshotsError);
      error(source === 'clipboard' ? status.clipboardError : status.screenshotsError);
      render();
    } catch (failure) {
      if (revision !== request) return;
      loaded = true; render(); error(failure.message || String(failure));
    }
  }
  function switchView(next) {
    if (view === next) return;
    view = next; selected = null; items = []; loaded = false; request += 1;
    closeMenu(); cancelDelete(); error('');
    for (const id of ['clipboard', 'screenshots']) {
      $(id).classList.toggle('nk-on', id === view);
      $(id).setAttribute('aria-selected', String(id === view));
      $(id).tabIndex = id === view ? 0 : -1;
    }
    render(); refresh();
  }
  function closeMenu(restore = false) {
    $('menu').hidden = true; $('actions').setAttribute('aria-expanded', 'false');
    if (restore) $('search').focus();
  }
  function showMenu() {
    const item = current();
    if (!item || busy) return;
    cancelDelete(); $('menu').replaceChildren();
    for (const [label, action, enabled] of [
      ['Copy to Clipboard', 'copy', true], ['Paste into App', 'paste', true],
      ['Open', 'open', D.canOpen(item)], ['Reveal in Finder', 'reveal', item.hasFile],
      ['Quick Look', 'quickLook', item.hasFile], [item.pinned ? 'Unpin' : 'Pin', item.pinned ? 'unpin' : 'pin', true],
      [item.hasFile ? 'Move to Trash…' : 'Delete…', 'delete', true]
    ]) {
      const button = document.createElement('button'); button.className = `nk-btn${action === 'delete' ? ' nk-danger' : ''}`;
      button.textContent = label; button.disabled = !enabled; button.setAttribute('role', 'menuitem');
      button.onclick = () => { closeMenu(); if (action === 'delete') prepareDelete(item); else run(action, item.id); };
      $('menu').append(button);
    }
    $('menu').hidden = false; $('actions').setAttribute('aria-expanded', 'true');
    $('menu').querySelector('button:not(:disabled)')?.focus();
  }
  function prepareDelete(item) {
    confirmationID = item.id;
    $('confirm-text').textContent = item.hasFile ? `Move ${item.kind === 'files' ? 'the original file(s)' : 'this file'} to Trash?` : 'Delete this clipboard item?';
    $('delete').textContent = item.hasFile ? 'Move to Trash' : 'Delete';
    $('confirmation').hidden = false; $('cancel').focus();
  }
  function cancelDelete() { confirmationID = null; $('confirmation').hidden = true; }
  async function run(action, id = selected) {
    if (!id || busy) return;
    busy = true; select(selected); error('');
    try {
      await featureAPI[action](id);
      cancelDelete();
      if (['delete', 'pin', 'unpin'].includes(action)) await refresh();
      feedback(action === 'copy' ? 'Copied to Clipboard' : action === 'paste' ? 'Pasted into App' : action === 'delete' ? 'Deleted' : '');
    } catch (failure) { error(failure.message || String(failure)); }
    finally { busy = false; select(selected); }
  }
  async function closeNotch() {
    try { await nook.notch.close(); }
    catch (failure) { error(failure.message || String(failure)); }
  }
  function keyboard(event) {
    if (event.defaultPrevented || event.isComposing) return;
    const command = event.metaKey || event.ctrlKey;
    if (event.key === 'Escape') {
      event.preventDefault(); event.stopPropagation();
      if (!$('menu').hidden || confirmationID) { closeMenu(true); cancelDelete(); }
      else closeNotch();
      return;
    }
    if (command && event.key.toLowerCase() === 'k') {
      event.preventDefault(); if ($('menu').hidden) showMenu(); else closeMenu(true); return;
    }
    if (!$('menu').hidden) {
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        const buttons = [...$('menu').querySelectorAll('button:not(:disabled)')];
        buttons[(buttons.indexOf(document.activeElement) + (event.key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length]?.focus();
      }
      return;
    }
    if (confirmationID || busy) return;
    if (event.target.closest('[role="tablist"]')) {
      if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') { event.preventDefault(); switchView(view === 'clipboard' ? 'screenshots' : 'clipboard'); $(view).focus(); }
      return;
    }
    if (event.target.closest('button')) return;
    if (event.key === 'Enter') { event.preventDefault(); run(command ? 'paste' : 'copy'); return; }
    if (!command && !event.altKey && ['ArrowDown', 'ArrowUp', 'ArrowLeft', 'ArrowRight'].includes(event.key)) {
      if (event.target === $('search') && ['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
      if (view === 'clipboard' && ['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
      event.preventDefault();
      const columns = view === 'screenshots' ? (window.innerWidth <= 460 ? 2 : 3) : 1;
      select(items[D.move(items.findIndex((item) => item.id === selected), event.key, items.length, columns)]?.id, true);
      $('content').focus({ preventScroll: true }); return;
    }
    if (event.key === ' ' && event.target !== $('search') && current()?.hasFile) { event.preventDefault(); run('quickLook'); }
  }
  async function subscribe(event, callback) { try { await (['clips', 'clipsError'].includes(event) ? nook.native.on(event, callback) : nook.on(event, callback)); } catch (failure) { error(failure.message || String(failure)); } }
  $('clipboard').onclick = () => switchView('clipboard'); $('screenshots').onclick = () => switchView('screenshots');
  $('search').oninput = () => { closeMenu(); cancelDelete(); clearTimeout(searchTimer); request += 1; searchTimer = setTimeout(refresh, 120); };
  $('refresh').onclick = refresh; $('retry').onclick = refresh;
  $('actions').onclick = () => $('menu').hidden ? showMenu() : closeMenu(true);
  $('cancel').onclick = () => { cancelDelete(); $('search').focus(); };
  $('delete').onclick = () => run('delete', confirmationID);
  document.addEventListener('keydown', keyboard);
  document.addEventListener('pointerdown', (event) => { if (!$('menu').contains(event.target) && !$('actions').contains(event.target)) closeMenu(); });
  async function initialize() {
    await subscribe('clips', refresh);
    const show = (tab) => { if (!tab || tab === 'clips') { $('search').focus(); refresh(); } };
    await subscribe('show', show); await subscribe('open', show);
    await subscribe('close', () => { closeMenu(); cancelDelete(); });
    await refresh();
  }
  nook.native.on('ready', refresh);
  nook.on('settings', refresh);
  initialize();
})();
