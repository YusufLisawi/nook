(() => {
  'use strict';

  // Storages live in nook.storage; their keys live in the macOS keychain (service KC, account = storage id).
  // The first storage is imported from BucketDrop itself and keeps reading BucketDrop's own keychain items.
  // All S3 calls use curl's built-in SigV4 signing, so nothing extra is installed.
  const BD = 'com.fayazahmed.BucketDrop';
  const KC = 'dev.nook.bucketdrop';
  const IMG = /\.(png|jpe?g|gif|webp|avif|svg)$/i;

  const $ = (id) => document.getElementById(id);
  const ui = {
    picker: $('picker'), pickName: $('pick-name'), pickHost: $('pick-host'), menu: $('menu'),
    q: $('q'), pick: $('pick'), paste: $('paste'), refresh: $('refresh'), settings: $('settings'),
    status: $('status'), list: $('list'), empty: $('empty'), drop: $('drop'), dropText: $('drop-text'),
    sheet: $('sheet'), sheetTitle: $('sheet-title'), back: $('sheet-back'), add: $('add'),
    storages: $('storages'), form: $('form'), formNote: $('form-note'), cancel: $('cancel')
  };
  let storages = [];
  let activeId = null;
  let objects = [];
  let editing = null; // storage being edited, or {} for a new one
  let statusTimer = null;
  let loadSeq = 0;

  const q = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;
  const enc = (key) => key.split('/').map((p) => encodeURIComponent(p).replace(/[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase())).join('/');
  const host = (url) => String(url || '').replace(/^https?:\/\//, '').replace(/\/.*$/, '');
  const active = () => storages.find((s) => s.id === activeId) || storages[0];
  const publicUrl = (st, key) => (st.publicBase ? st.publicBase.replace(/\/$/, '') : `${st.endpoint}/${st.bucket}`) + '/' + enc(key);
  const displayName = (key) => key.replace(/^[0-9A-Fa-f]{8}-/, '');
  const size = (n) => n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(1)} KB` : n < 1073741824 ? `${(n / 1048576).toFixed(1)} MB` : `${(n / 1073741824).toFixed(2)} GB`;
  function ago(date) {
    const s = (Date.now() - date) / 1000;
    if (s < 60) return 'Just now';
    if (s < 3600) return `${Math.floor(s / 60)}m ago`;
    if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
    if (s < 604800) return `${Math.floor(s / 86400)}d ago`;
    return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  }

  function status(text, tone, sticky) {
    clearTimeout(statusTimer);
    ui.status.hidden = !text;
    ui.status.dataset.tone = tone || '';
    ui.status.innerHTML = tone === 'busy' ? '<span class="spin"></span>' : '';
    ui.status.append(text || '');
    if (text && !sticky && tone !== 'busy') statusTimer = setTimeout(() => (ui.status.hidden = true), 4000);
  }

  function icon(name) {
    return `<svg class="icon"><use href="#${name}"/></svg>`;
  }

  // ---- S3 over curl -------------------------------------------------------

  function keysFor(st, override) {
    if (override) return `AK=${q(override.ak)}; SK=${q(override.sk)}`;
    if (st.keys === 'bucketdrop') return `AK=$(security find-generic-password -s ${BD} -a s3_access_key_id -w 2>/dev/null) || { echo NOKEYS; exit 3; }
SK=$(security find-generic-password -s ${BD} -a s3_secret_access_key -w 2>/dev/null) || { echo NOKEYS; exit 3; }`;
    return `C=$(security find-generic-password -s ${KC} -a ${q(st.id)} -w 2>/dev/null) || { echo NOKEYS; exit 3; }
AK=\${C%%:*}; SK=\${C#*:}`;
  }

  // Runs `cmd` with $EP/$B and an `s3` curl helper; returns the response body or throws a readable error.
  async function s3(st, cmd, override) {
    const env = `${keysFor(st, override)}
EP=${q(st.endpoint.replace(/\/$/, ''))}; B=${q(st.bucket)}; R=${q(st.region || 'auto')}
s3() { printf 'user = "%s:%s"\\n' "$AK" "$SK" | curl -sS -g -K - --aws-sigv4 "aws:amz:\${R}:s3" -w '\\n%{http_code}' "$@"; }`;
    const r = await nook.shell(`${env}\n${cmd}`, { timeout: 900 });
    if (r.stdout.trim() === 'NOKEYS') throw new Error('Keys not found in the keychain. Edit this storage and add them.');
    const m = r.stdout.match(/\n?(\d{3})\s*$/);
    const http = m ? Number(m[1]) : 0;
    const body = m ? r.stdout.slice(0, m.index) : r.stdout;
    if (r.code !== 0 || !http || http >= 300) {
      throw new Error(body.match(/<Message>(.*?)<\/Message>/)?.[1] || body.match(/<Code>(.*?)<\/Code>/)?.[1] || r.stderr.trim() || `HTTP ${http}`);
    }
    return body;
  }

  // ---- Storages -----------------------------------------------------------

  async function loadStorages() {
    const saved = await nook.storage.all();
    storages = Array.isArray(saved.storages) ? saved.storages : [];
    activeId = saved.active || null;
    if (!storages.length) {
      const r = await nook.shell(`for k in s3_endpoint s3_bucket s3_region s3_public_url_base; do defaults read ${BD} $k 2>/dev/null || echo; done`);
      const [endpoint, bucket, region, publicBase] = r.stdout.split('\n').map((s) => s.trim());
      if (endpoint && bucket) {
        storages = [{ id: 'bucketdrop', name: bucket, endpoint, bucket, region: region || 'auto', publicBase, keys: 'bucketdrop' }];
        await saveStorages();
      }
    }
    if (!active()) activeId = storages[0]?.id || null;
  }

  async function saveStorages() {
    await nook.storage.set('storages', storages);
    await nook.storage.set('active', activeId);
  }

  function renderPicker() {
    const st = active();
    ui.pickName.textContent = st ? st.name || st.bucket : 'No storage yet';
    ui.pickHost.textContent = st ? `${st.bucket} · ${host(st.publicBase || st.endpoint)}` : 'Add one to start uploading';
  }

  function renderMenu() {
    ui.menu.replaceChildren(...storages.map((st) => {
      const b = document.createElement('button');
      b.innerHTML = `<span class="badge">${icon('i-bucket')}</span><span class="m-text"><strong></strong><span></span></span>`;
      b.querySelector('strong').textContent = st.name || st.bucket;
      b.querySelector('.m-text span').textContent = `${st.bucket} · ${host(st.publicBase || st.endpoint)}`;
      if (st.id === active()?.id) b.insertAdjacentHTML('beforeend', '<svg class="icon m-check"><use href="#i-check"/></svg>');
      b.onclick = () => select(st.id);
      return b;
    }));
    if (storages.length) ui.menu.append(document.createElement('hr'));
    const manage = document.createElement('button');
    manage.innerHTML = `${icon('i-gear')}<span class="m-text">Manage storages…</span>`;
    manage.onclick = () => { closeMenu(); openSheet(); };
    ui.menu.append(manage);
  }

  function closeMenu() { ui.menu.hidden = true; }

  async function select(id) {
    closeMenu();
    if (id === activeId) return;
    activeId = id;
    await saveStorages();
    renderPicker();
    objects = [];
    render();
    refresh();
  }

  // ---- File list ----------------------------------------------------------

  async function refresh() {
    const st = active();
    renderPicker();
    if (!st) { objects = []; render(); ui.empty.textContent = 'Add a storage to start uploading'; return; }
    const seq = ++loadSeq;
    ui.refresh.disabled = true;
    try {
      const xml = await s3(st, `s3 "$EP/$B?list-type=2&max-keys=1000"`);
      if (seq !== loadSeq) return;
      const doc = new DOMParser().parseFromString(xml, 'application/xml');
      const text = (c, tag) => c.getElementsByTagName(tag)[0]?.textContent || '';
      objects = [...doc.getElementsByTagName('Contents')].map((c) => ({
        key: text(c, 'Key'), size: Number(text(c, 'Size')), date: new Date(text(c, 'LastModified'))
      })).sort((a, b) => b.date - a.date);
      render();
    } catch (e) {
      if (seq !== loadSeq) return;
      objects = [];
      render();
      ui.empty.textContent = 'Could not load this bucket';
      status(e.message, 'bad', true);
    } finally {
      if (seq === loadSeq) ui.refresh.disabled = false;
    }
  }

  function iconButton(name, title, onClick, cls = '') {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = `icon-btn ${cls}`;
    b.title = title;
    b.innerHTML = icon(name);
    b.onclick = onClick;
    return b;
  }

  // First click arms the button, a second click within 3s runs `action`.
  function confirmClick(btn, action) {
    if (!btn.dataset.armed) {
      btn.dataset.armed = '1';
      btn.style.color = '#ff726b';
      const title = btn.title;
      btn.title = 'Click again to delete';
      setTimeout(() => { delete btn.dataset.armed; btn.style.color = ''; btn.title = title; }, 3000);
      return;
    }
    action();
  }

  function render() {
    const st = active();
    const term = ui.q.value.trim().toLowerCase();
    const shown = objects.filter((o) => !term || o.key.toLowerCase().includes(term)).slice(0, 200);
    ui.list.replaceChildren(...shown.map((o) => {
      const li = document.createElement('li');
      li.className = 'row';
      const thumb = document.createElement('div');
      thumb.className = 'thumb';
      if (st.publicBase && IMG.test(o.key)) thumb.style.backgroundImage = `url("${publicUrl(st, o.key)}")`;
      else thumb.innerHTML = icon('i-file');
      const meta = document.createElement('div');
      meta.className = 'meta';
      meta.innerHTML = '<div class="name"></div><div class="sub"></div>';
      meta.firstChild.textContent = displayName(o.key);
      meta.firstChild.title = o.key;
      meta.lastChild.textContent = `${size(o.size)} · ${ago(o.date)}`;
      const acts = document.createElement('div');
      acts.className = 'acts';
      const del = iconButton('i-trash', 'Delete', () => confirmClick(del, () => remove(st, o)), 'danger');
      acts.append(
        iconButton('i-link', 'Copy link', () => copyLink(st, o.key)),
        iconButton('i-open', 'Open', () => nook.open(publicUrl(st, o.key))),
        del
      );
      li.append(thumb, meta, acts);
      return li;
    }));
    ui.empty.hidden = shown.length > 0;
    ui.empty.textContent = term ? 'No matches' : 'Drop files or folders here to upload';
  }

  async function copyLink(st, key) {
    await nook.clipboard.write(publicUrl(st, key));
    status('Link copied', 'good');
  }

  async function remove(st, o) {
    try {
      await s3(st, `s3 -X DELETE "$EP/$B/${enc(o.key)}"`);
      objects = objects.filter((x) => x !== o);
      render();
      status(`Deleted ${displayName(o.key)}`, 'good');
    } catch (e) {
      status(`Delete failed: ${e.message}`, 'bad');
    }
  }

  // ---- Uploading ----------------------------------------------------------

  // Folders are zipped first (Finder-style "Name.zip"); files go up as they are.
  async function prepare(path) {
    const r = await nook.shell(`f=${q(path)}
if [ -d "$f" ]; then d=$(mktemp -d /tmp/nook-bucketdrop.XXXXXX); z="$d/$(basename "$f").zip"
  ditto -c -k --norsrc --noextattr --keepParent "$f" "$z" && echo "$z"
else echo "$f"; fi`, { timeout: 900 });
    const out = r.stdout.trim();
    if (r.code !== 0 || !out) throw new Error(r.stderr.trim() || 'Could not compress the folder');
    return out;
  }

  // Same key shape as BucketDrop: 8 random hex chars + "-" + filename.
  async function upload(paths) {
    const st = active();
    if (!paths.length) return;
    if (!st) return status('Add a storage first.', 'bad');
    const links = [];
    nook.activity.set({ text: 'Uploading…', symbol: 'arrow.up.circle', color: '#ff9f0a' });
    for (const [i, original] of paths.entries()) {
      const count = paths.length > 1 ? `${i + 1}/${paths.length} · ` : '';
      let name = original.split('/').pop();
      try {
        const isDir = (await nook.shell(`[ -d ${q(original)} ] && echo dir`)).stdout.trim() === 'dir';
        if (isDir) status(`${count}Compressing ${name}…`, 'busy');
        const path = await prepare(original);
        name = path.split('/').pop();
        status(`${count}Uploading ${name}`, 'busy');
        const key = `${crypto.randomUUID().replace(/-/g, '').slice(0, 8).toUpperCase()}-${name}`;
        await s3(st, `f=${q(path)}; s3 -H "Content-Type: $(file -b --mime-type "$f")" -T "$f" "$EP/$B/${enc(key)}"`);
        links.push(publicUrl(st, key));
      } catch (e) {
        status(`${name}: ${e.message}`, 'bad', true);
        nook.activity.clear();
        nook.notify('Upload failed', `${name}: ${e.message}`);
        return refresh();
      }
    }
    await nook.clipboard.write(links.join('\n'));
    status(links.length > 1 ? `${links.length} links copied` : 'Uploaded · link copied', 'good');
    nook.activity.set({ text: 'Link copied', symbol: 'checkmark.circle.fill', color: '#30d158' });
    setTimeout(() => nook.activity.clear(), 3000);
    refresh();
  }

  async function pick() {
    nook.notch.pin(true);
    try {
      const r = await nook.shell(`osascript -e 'set out to ""' -e 'repeat with f in (choose file with prompt "Upload to bucket" with multiple selections allowed)' -e 'set out to out & POSIX path of f & linefeed' -e 'end repeat' -e 'return out'`, { timeout: 600 });
      await upload(r.stdout.split('\n').filter(Boolean));
    } finally {
      nook.notch.pin(false);
    }
  }

  // Clipboard: a copied file or folder (Finder) wins; otherwise a copied image is saved as PNG.
  async function pasteUpload() {
    const r = await nook.shell(`p=$(osascript -e 'POSIX path of (the clipboard as «class furl»)' 2>/dev/null) && { echo "$p"; exit; }
d=$(mktemp -d /tmp/nook-bucketdrop.XXXXXX); f="$d/Clipboard $(date +%Y-%m-%d\\ at\\ %H.%M.%S).png"
osascript -e "set f to open for access POSIX file \\"$f\\" with write permission" -e 'write (the clipboard as «class PNGf») to f' -e 'close access f' >/dev/null 2>&1 && echo "$f"`);
    const path = r.stdout.trim().replace(/\/$/, '');
    if (!path) return status('Nothing to upload. Copy a file or an image first.', 'bad');
    upload([path]);
  }

  // Nook hands us real paths for dropped files and folders.
  nook.on('dragenter', () => {
    ui.dropText.textContent = active() ? `Drop to upload to ${active().name || active().bucket}` : 'Add a storage first';
    ui.drop.hidden = false;
  });
  nook.on('dragleave', () => (ui.drop.hidden = true));
  nook.on('drop', (paths) => {
    ui.drop.hidden = true;
    closeSheet();
    upload((paths || []).map((p) => p.replace(/\/$/, '')));
  });

  // ---- Storages sheet -----------------------------------------------------

  function openSheet() {
    ui.sheet.hidden = false;
    showStorageList();
  }

  function closeSheet() {
    ui.sheet.hidden = true;
    editing = null;
  }

  function showStorageList() {
    editing = null;
    ui.sheetTitle.textContent = 'Storages';
    ui.form.hidden = true;
    ui.storages.hidden = false;
    ui.add.hidden = false;
    ui.storages.replaceChildren(...storages.map((st) => {
      const li = document.createElement('li');
      li.className = 'row';
      li.innerHTML = `<span class="badge">${icon('i-bucket')}</span><div class="meta"><div class="name"></div><div class="sub"></div></div><div class="acts"></div>`;
      li.querySelector('.name').textContent = st.name || st.bucket;
      li.querySelector('.sub').textContent = `${st.bucket} · ${host(st.publicBase || st.endpoint)}`;
      if (st.keys === 'bucketdrop') li.querySelector('.name').insertAdjacentHTML('beforeend', ' <span class="pill">BucketDrop keys</span>');
      const del = iconButton('i-trash', 'Delete storage', () => confirmClick(del, () => deleteStorage(st)), 'danger');
      li.querySelector('.acts').append(iconButton('i-edit', 'Edit', () => showForm(st)), del);
      return li;
    }));
    if (!storages.length) ui.storages.innerHTML = '<li class="empty" style="position:static;height:100%">No storages yet. Add one.</li>';
  }

  function showForm(st) {
    editing = st || {};
    ui.sheetTitle.textContent = st ? `Edit ${st.name || st.bucket}` : 'New storage';
    ui.storages.hidden = true;
    ui.add.hidden = true;
    ui.form.hidden = false;
    const f = ui.form.elements;
    for (const k of ['name', 'bucket', 'endpoint', 'region', 'publicBase']) f[k].value = st?.[k] || '';
    f.ak.value = '';
    f.sk.value = '';
    f.ak.placeholder = f.sk.placeholder = st ? 'Leave empty to keep the saved key' : '';
    f.ak.required = f.sk.required = !st;
    ui.formNote.textContent = 'Keys are saved in your macOS keychain.';
    f.name.focus();
  }

  async function submitForm(e) {
    e.preventDefault();
    const f = ui.form.elements;
    const isNew = !editing.id;
    const st = {
      id: editing.id || `s${Date.now().toString(36)}`,
      name: f.name.value.trim() || f.bucket.value.trim(),
      bucket: f.bucket.value.trim(),
      endpoint: f.endpoint.value.trim().replace(/\/$/, ''),
      region: f.region.value.trim() || 'auto',
      publicBase: f.publicBase.value.trim().replace(/\/$/, ''),
      keys: editing.keys || 'keychain'
    };
    if (!/^https?:\/\//.test(st.endpoint)) st.endpoint = `https://${st.endpoint}`;
    const newKeys = f.ak.value.trim() && f.sk.value.trim() ? { ak: f.ak.value.trim(), sk: f.sk.value.trim() } : null;
    if (newKeys && st.keys === 'bucketdrop') st.keys = 'keychain';
    ui.formNote.textContent = 'Testing the connection…';
    try {
      await s3(st, `s3 "$EP/$B?list-type=2&max-keys=1"`, newKeys);
      if (newKeys) {
        const r = await nook.shell(`security add-generic-password -U -s ${KC} -a ${q(st.id)} -l ${q(`Nook BucketDrop · ${st.name}`)} -w ${q(`${newKeys.ak}:${newKeys.sk}`)}`);
        if (r.code !== 0) throw new Error(`Could not save keys: ${r.stderr.trim()}`);
      }
    } catch (err) {
      ui.formNote.textContent = `Failed: ${err.message}`;
      return;
    }
    storages = isNew ? [...storages, st] : storages.map((x) => (x.id === st.id ? st : x));
    if (isNew || !activeId) activeId = st.id;
    await saveStorages();
    renderPicker();
    showStorageList();
    status(`Saved ${st.name}`, 'good');
    refresh();
  }

  async function deleteStorage(st) {
    if (st.keys === 'keychain') await nook.shell(`security delete-generic-password -s ${KC} -a ${q(st.id)} >/dev/null 2>&1`);
    storages = storages.filter((x) => x.id !== st.id);
    if (activeId === st.id) activeId = storages[0]?.id || null;
    await saveStorages();
    showStorageList();
    refresh();
  }

  // ---- Wiring -------------------------------------------------------------

  ui.picker.onclick = (e) => {
    e.stopPropagation();
    if (ui.menu.hidden) renderMenu();
    ui.menu.hidden = !ui.menu.hidden;
  };
  document.addEventListener('click', (e) => { if (!ui.menu.contains(e.target)) closeMenu(); });
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    if (!ui.menu.hidden) closeMenu();
    else if (editing) showStorageList();
    else if (!ui.sheet.hidden) closeSheet();
  });
  // Stop WebKit from opening anything dropped that Nook didn't handle (e.g. a link).
  document.addEventListener('dragover', (e) => e.preventDefault());
  document.addEventListener('drop', (e) => e.preventDefault());

  ui.pick.onclick = pick;
  ui.paste.onclick = pasteUpload;
  ui.refresh.onclick = refresh;
  ui.settings.onclick = openSheet;
  ui.q.oninput = render;
  ui.add.onclick = () => showForm(null);
  ui.cancel.onclick = showStorageList;
  ui.back.onclick = () => (editing ? showStorageList() : closeSheet());
  ui.form.onsubmit = submitForm;
  nook.on('show', refresh);

  loadStorages().then(() => (storages.length ? refresh() : (renderPicker(), openSheet())));
})();
