(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const SVG_NS = 'http://www.w3.org/2000/svg';
  let snapshot = { proxies: [], activeId: null };
  let loaded = false;
  let pending = null;
  let editing = null;
  let clickTimer = null;
  let revision = 0;
  let ipRevision = 0;
  let listRevision = 0;
  let ipBusy = false;
  let listBusy = false;
  let disposed = false;

  function icon(name, className = '') {
    const svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('class', `icon ${className}`);
    svg.setAttribute('aria-hidden', 'true');
    const use = document.createElementNS(SVG_NS, 'use');
    use.setAttribute('href', `#icon-${name}`);
    svg.append(use);
    return svg;
  }

  function spinner() {
    const node = document.createElement('span');
    node.className = 'spinner';
    node.setAttribute('aria-hidden', 'true');
    return node;
  }

  function error(message) {
    $('message-text').textContent = message;
    $('message').hidden = false;
  }

  function clearError() { $('message').hidden = true; }

  function setExpanded(expanded) {
    $('add-toggle').setAttribute('aria-expanded', String(expanded));
    $('add-form').hidden = !expanded;
  }

  function renderHeader() {
    const active = snapshot.proxies.find(proxy => proxy.id === snapshot.activeId);
    const connected = snapshot.activeId !== null;
    const switching = pending?.type === 'connect' || pending?.type === 'disconnect';
    $('connection-name').textContent = switching ? pending.type === 'disconnect' ? 'Disconnecting…' : 'Connecting…' : !loaded ? listBusy ? 'Loading…' : 'Unavailable' : connected ? active?.name || 'Connected proxy' : 'Direct';
    $('status-pill').classList.toggle('connected', connected);
    $('status-pill').classList.toggle('pending', switching);
    $('disconnect').hidden = !connected;
    $('disconnect').disabled = !!pending;
    $('refresh').disabled = ipBusy || listBusy || !!pending;
    $('refresh').classList.toggle('spinning', ipBusy || listBusy);
    $('add-button').disabled = !!pending || !$('proxy-input').value.trim();
    $('add-button').querySelector('span').textContent = pending?.type === 'add' ? 'Adding…' : 'Add';
    $('proxy-input').disabled = pending?.type === 'add';
  }

  function actionButton(label, glyph, className, handler) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `icon-button ${className}`;
    button.title = label;
    button.setAttribute('aria-label', label);
    button.disabled = !!pending;
    button.append(icon(glyph));
    button.addEventListener('click', handler);
    return button;
  }

  function startRename(proxy) {
    clearTimeout(clickTimer);
    if (pending) return;
    editing = proxy.id;
    renderList(true);
    const input = $('proxy-list').querySelector('.rename-form input');
    if (input) { input.focus(); input.select(); }
  }

  function renameForm(proxy) {
    const form = document.createElement('form');
    form.className = 'rename-form';
    const input = document.createElement('input');
    input.value = proxy.name || '';
    input.maxLength = 120;
    input.setAttribute('aria-label', 'Proxy name');
    input.autocomplete = 'off';
    const save = document.createElement('button');
    save.className = 'button';
    save.type = 'submit';
    save.textContent = 'Save';
    const cancel = actionButton('Cancel rename', 'close', '', () => { editing = null; renderList(true); });
    form.append(input, save, cancel);
    form.addEventListener('submit', event => {
      event.preventDefault();
      const name = input.value.trim();
      if (!name) { error('Give this proxy a name before saving.'); input.focus(); return; }
      editing = null;
      if (name === proxy.name) { renderList(true); return; }
      void mutate('rename', proxy.id, name);
    });
    input.addEventListener('keydown', event => {
      if (event.key === 'Escape') { event.preventDefault(); editing = null; renderList(true); }
    });
    return form;
  }

  function renderList(force = false) {
    if (editing && !force && $('proxy-list').contains(document.activeElement)) return;
    const scrollTop = $('proxy-list').scrollTop;
    if (editing && !snapshot.proxies.some(proxy => proxy.id === editing)) editing = null;
    const rows = snapshot.proxies.map(proxy => {
      const active = proxy.id === snapshot.activeId;
      const isPending = pending?.id === proxy.id;
      const row = document.createElement('div');
      row.className = `proxy-row${active ? ' active' : ''}${isPending ? ' pending' : ''}`;
      row.dataset.proxyId = proxy.id;
      if (editing === proxy.id) { row.append(renameForm(proxy)); return row; }
      const connect = document.createElement('button');
      connect.type = 'button';
      connect.className = 'connect-row';
      connect.dataset.nkItem = proxy.id;
      connect.addEventListener('nk:alt', () => startRename(proxy));
      connect.disabled = !!pending;
      connect.title = 'Click to connect · double-click to rename';
      connect.setAttribute('aria-label', `${active ? 'Connected to' : 'Connect to'} ${proxy.name}`);
      connect.setAttribute('aria-pressed', String(active));
      const indicator = document.createElement('span');
      indicator.className = 'row-indicator';
      indicator.append(isPending ? spinner() : icon(active ? 'check' : 'globe'));
      const copy = document.createElement('span');
      copy.className = 'row-copy';
      const nameLine = document.createElement('span');
      nameLine.className = 'proxy-name-line';
      const name = document.createElement('span');
      name.className = 'proxy-name';
      name.textContent = proxy.name || `${proxy.host}:${proxy.port}`;
      nameLine.append(name);
      if (proxy.hasAuth) {
        const lock = icon('lock', 'auth-icon');
        const label = document.createElement('span');
        label.title = 'Authentication configured';
        label.setAttribute('aria-label', 'Authentication configured');
        label.append(lock);
        nameLine.append(label);
      }
      const address = document.createElement('span');
      address.className = 'proxy-address';
      const host = String(proxy.host || 'Unknown host');
      const displayHost = host.includes(':') && !host.startsWith('[') ? `[${host}]` : host;
      address.textContent = `${String(proxy.scheme || 'http').toUpperCase()} · ${displayHost}:${proxy.port ?? '—'}`;
      address.title = address.textContent;
      copy.append(nameLine, address);
      connect.append(indicator, copy);
      connect.addEventListener('click', event => {
        clearTimeout(clickTimer);
        if (event.detail > 1 || pending) return;
        if (event.detail === 0) { if (!active) void mutate('connect', proxy.id); return; }
        clickTimer = setTimeout(() => { if (!active && !editing && !pending && !disposed) void mutate('connect', proxy.id); }, 350);
      });
      connect.addEventListener('dblclick', event => { event.preventDefault(); startRename(proxy); });
      const actions = document.createElement('div');
      actions.className = 'row-actions';
      actions.append(
        actionButton(`Rename ${proxy.name}`, 'edit', '', () => startRename(proxy)),
        actionButton(`Delete ${proxy.name}`, 'trash', 'delete', () => { clearTimeout(clickTimer); void mutate('remove', proxy.id); })
      );
      row.append(connect, actions);
      return row;
    });
    if (!rows.length) {
      const empty = document.createElement('div');
      empty.className = 'empty-state';
      const text = document.createElement('span');
      text.textContent = loaded ? 'Your proxies, one click away. Add one below.' : 'Can’t load proxies. Use refresh to try again.';
      empty.append(icon('globe'), text);
      rows.push(empty);
    }
    $('proxy-list').replaceChildren(...rows);
    $('proxy-list').scrollTop = scrollTop;
  }

  function applySnapshot(next, refreshOnChange = true) {
    if (!next || !Array.isArray(next.proxies)) throw new Error('Invalid proxy list');
    const oldActive = snapshot.activeId;
    const firstLoad = !loaded;
    snapshot = {
      proxies: next.proxies.filter(proxy => proxy && typeof proxy.id === 'string'),
      activeId: typeof next.activeId === 'string' ? next.activeId : null
    };
    loaded = true;
    if (firstLoad && !snapshot.proxies.length) setExpanded(true);
    renderHeader();
    renderList();
    if (refreshOnChange && oldActive !== snapshot.activeId) void refreshIP();
  }

  async function refreshList(refreshOnChange = true) {
    const request = ++listRevision;
    const eventRevision = revision;
    listBusy = true;
    renderHeader();
    try {
      if (!window.nook?.proxy?.list) throw new Error('Bridge unavailable');
      const next = await window.nook.proxy.list();
      if (!disposed && request === listRevision && eventRevision === revision) applySnapshot(next, refreshOnChange);
      return true;
    } catch (_) {
      if (request === listRevision) {
        error('Can’t load your proxies. Use refresh to try again.');
        renderList();
      }
      return false;
    } finally {
      if (request === listRevision) { listBusy = false; renderHeader(); }
    }
  }

  async function refreshIP() {
    const request = ++ipRevision;
    ipBusy = true;
    $('ip-line').classList.remove('error');
    $('ip-flag').textContent = '';
    $('ip-address').textContent = 'Checking public IP…';
    $('ip-location').textContent = '';
    renderHeader();
    try {
      if (!window.nook?.proxy?.ip) throw new Error('Bridge unavailable');
      const result = await window.nook.proxy.ip();
      if (request !== ipRevision || disposed) return;
      if (!result || typeof result.ip !== 'string' || !result.ip.trim()) throw new Error('IP unavailable');
      $('ip-address').textContent = result.ip;
      let flag = typeof result.flag === 'string' ? result.flag : '';
      if (!flag && /^[a-z]{2}$/i.test(result.countryCode || '')) {
        flag = [...result.countryCode.toUpperCase()].map(character => String.fromCodePoint(character.charCodeAt(0) + 127397)).join('');
      }
      $('ip-flag').textContent = flag;
      const location = [result.city, result.country].filter(value => typeof value === 'string' && value.trim()).join(', ');
      $('ip-location').textContent = location ? `· ${location}` : '';
      $('ip-line').title = [result.ip, location].filter(Boolean).join(' · ');
    } catch (_) {
      if (request !== ipRevision || disposed) return;
      $('ip-line').classList.add('error');
      $('ip-address').textContent = 'Can’t check public IP. Try refresh.';
      $('ip-line').title = '';
    } finally {
      if (request === ipRevision) { ipBusy = false; renderHeader(); }
    }
  }

  const count = value => Array.isArray(value) ? value.length : Number.isFinite(value) ? Math.max(0, Math.floor(value)) : null;

  async function mutate(type, id = null, value = null) {
    if (pending || disposed) return;
    if (editing && type !== 'rename') { editing = null; }
    pending = { type, id };
    clearError();
    renderHeader();
    renderList(true);
    try {
      if (!window.nook?.proxy) throw new Error('Bridge unavailable');
      if (type === 'connect') await window.nook.proxy.connect(id);
      else if (type === 'disconnect') await window.nook.proxy.disconnect();
      else if (type === 'remove') await window.nook.proxy.remove(id);
      else if (type === 'rename') await window.nook.proxy.rename(id, value);
      else if (type === 'add') {
        const result = await window.nook.proxy.add(value);
        const added = count(result?.added);
        const bad = count(result?.bad);
        if (added === null || bad === null) throw new Error('Invalid add result');
        $('add-result').textContent = `Added ${added} · ${bad} not understood`;
        $('add-result').classList.toggle('has-bad', bad > 0);
        if (bad === 0) $('proxy-input').value = '';
        else if (Array.isArray(result.bad) && result.bad.every(item => typeof item === 'string')) $('proxy-input').value = result.bad.join('\n');
      }
      const previousActive = snapshot.activeId;
      await refreshList(false);
      if (type === 'connect' || type === 'disconnect' || previousActive !== snapshot.activeId || (type === 'remove' && id === previousActive)) await refreshIP();
    } catch (_) {
      const messages = {
        connect: 'Couldn’t connect. Check this proxy and try again.',
        disconnect: 'Couldn’t disconnect. Please try again.',
        remove: 'Couldn’t delete this proxy. Please try again.',
        rename: 'Couldn’t save the name. Please try again.',
        add: 'Couldn’t add proxies. Check the addresses and try again.'
      };
      error(messages[type] || 'Something went wrong. Please try again.');
      // A failed switch can still have changed the native connection state.
      if (type === 'connect' || type === 'disconnect') { await refreshList(false); await refreshIP(); }
    } finally {
      pending = null;
      renderHeader();
      renderList(true);
    }
  }

  $('add-toggle').addEventListener('click', () => {
    const expanded = $('add-toggle').getAttribute('aria-expanded') !== 'true';
    setExpanded(expanded);
    if (expanded) $('proxy-input').focus();
  });
  $('proxy-input').addEventListener('input', renderHeader);
  $('add-form').addEventListener('submit', event => {
    event.preventDefault();
    const value = $('proxy-input').value.trim();
    if (value) void mutate('add', null, value);
  });
  $('disconnect').addEventListener('click', () => { void mutate('disconnect', snapshot.activeId); });
  $('refresh').addEventListener('click', async () => {
    clearError();
    await refreshList(false);
    await refreshIP();
  });
  $('dismiss-message').addEventListener('click', clearError);

  async function start() {
    try {
      if (!window.nook?.on) throw new Error('Bridge unavailable');
      await window.nook.on('proxy', next => {
        if (disposed) return;
        try { revision += 1; applySnapshot(next); }
        catch (_) { error('Couldn’t update the list. Use refresh to sync.'); }
      });
    } catch (_) { error('Live updates are unavailable. Use refresh to sync.'); }
    await refreshList(false);
    await refreshIP();
  }
  window.addEventListener('pagehide', () => { disposed = true; clearTimeout(clickTimer); }, { once: true });
  void start();
})();
