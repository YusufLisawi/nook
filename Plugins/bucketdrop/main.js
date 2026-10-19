(() => {
  'use strict';

  // Reuses BucketDrop's own settings: bucket/endpoint in its defaults, keys in its keychain items.
  // All S3 calls go through curl's built-in SigV4 signing, so nothing extra is installed.
  const SVC = 'com.fayazahmed.BucketDrop';
  const ENV = `S=${SVC}
AK=$(security find-generic-password -s $S -a s3_access_key_id -w 2>/dev/null) || { echo NOKEYS; exit 3; }
SK=$(security find-generic-password -s $S -a s3_secret_access_key -w 2>/dev/null) || { echo NOKEYS; exit 3; }
EP=$(defaults read $S s3_endpoint); EP=\${EP%/}; B=$(defaults read $S s3_bucket)
R=$(defaults read $S s3_region 2>/dev/null || echo auto)
s3() { printf 'user = "%s:%s"\\n' "$AK" "$SK" | curl -sS -g -K - --aws-sigv4 "aws:amz:\${R}:s3" -w '\\n%{http_code}' "$@"; }`;
  const IMG = /\.(png|jpe?g|gif|webp|heic|avif|svg)$/i;

  const $ = (id) => document.getElementById(id);
  const ui = { where: $('where'), q: $('q'), pick: $('pick'), paste: $('paste'), refresh: $('refresh'), status: $('status'), list: $('list'), empty: $('empty'), drop: $('drop') };
  let cfg = null;
  let objects = [];
  let statusTimer = null;

  const q = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;
  const enc = (key) => key.split('/').map((p) => encodeURIComponent(p).replace(/[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase())).join('/');
  const publicUrl = (key) => (cfg.publicBase ? cfg.publicBase.replace(/\/$/, '') : `${cfg.endpoint}/${cfg.bucket}`) + '/' + enc(key);
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

  // Runs a curl call; returns { http, body } or throws with a readable message.
  async function s3(cmd) {
    const r = await nook.shell(`${ENV}\n${cmd}`, { timeout: 600 });
    if (r.stdout.trim() === 'NOKEYS') throw new Error('Keys not found. Open BucketDrop and save your settings, or allow keychain access.');
    const out = r.stdout.replace(/\n?(\d{3})\s*$/, '');
    const http = Number(RegExp.$1) || 0;
    if (r.code !== 0 || http >= 300 || !http) {
      const msg = out.match(/<Message>(.*?)<\/Message>/)?.[1] || r.stderr.trim() || `HTTP ${http}`;
      throw new Error(msg);
    }
    return out;
  }

  async function loadConfig() {
    const r = await nook.shell(`for k in s3_endpoint s3_bucket s3_public_url_base; do defaults read ${SVC} $k 2>/dev/null || echo; done`);
    const [endpoint, bucket, publicBase] = r.stdout.split('\n').map((s) => s.trim());
    if (!endpoint || !bucket) throw new Error('BucketDrop is not set up yet. Open BucketDrop settings first.');
    cfg = { endpoint: endpoint.replace(/\/$/, ''), bucket, publicBase };
    ui.where.textContent = `${bucket} · ${(publicBase || endpoint).replace(/^https?:\/\//, '')}`;
  }

  async function refresh() {
    ui.refresh.disabled = true;
    try {
      if (!cfg) await loadConfig();
      const xml = await s3(`s3 "$EP/$B?list-type=2&max-keys=1000"`);
      const doc = new DOMParser().parseFromString(xml, 'application/xml');
      objects = [...doc.getElementsByTagName('Contents')].map((c) => ({
        key: c.getElementsByTagName('Key')[0].textContent,
        size: Number(c.getElementsByTagName('Size')[0].textContent),
        date: new Date(c.getElementsByTagName('LastModified')[0].textContent)
      })).sort((a, b) => b.date - a.date);
      render();
    } catch (e) {
      status(e.message, 'bad', true);
      ui.empty.textContent = 'Could not load the bucket';
    } finally {
      ui.refresh.disabled = false;
    }
  }

  function button(icon, title, onClick, cls = '') {
    const b = document.createElement('button');
    b.className = `icon-btn ${cls}`;
    b.title = title;
    b.innerHTML = `<svg class="icon"><use href="#${icon}"/></svg>`;
    b.onclick = onClick;
    return b;
  }

  function render() {
    const term = ui.q.value.trim().toLowerCase();
    const shown = objects.filter((o) => !term || o.key.toLowerCase().includes(term)).slice(0, 200);
    ui.list.replaceChildren(...shown.map((o) => {
      const li = document.createElement('li');
      li.className = 'row';
      const thumb = document.createElement('div');
      thumb.className = 'thumb';
      if (IMG.test(o.key)) thumb.style.backgroundImage = `url("${publicUrl(o.key)}")`;
      else thumb.innerHTML = '<svg class="icon"><use href="#i-file"/></svg>';
      const meta = document.createElement('div');
      meta.className = 'meta';
      meta.innerHTML = '<div class="name"></div><div class="sub"></div>';
      meta.firstChild.textContent = displayName(o.key);
      meta.firstChild.title = o.key;
      meta.lastChild.textContent = `${size(o.size)} · ${ago(o.date)}`;
      const acts = document.createElement('div');
      acts.className = 'acts';
      const del = button('i-trash', 'Delete', () => remove(o, del), 'danger');
      acts.append(
        button('i-link', 'Copy link', () => copyLink(o.key)),
        button('i-open', 'Open', () => nook.open(publicUrl(o.key))),
        del
      );
      li.append(thumb, meta, acts);
      return li;
    }));
    ui.empty.hidden = shown.length > 0;
    ui.empty.textContent = term ? 'No matches' : 'Drop files here to upload';
  }

  async function copyLink(key) {
    await nook.clipboard.write(publicUrl(key));
    status('Link copied', 'good');
  }

  // First click arms the button, second click within 3s deletes.
  async function remove(o, btn) {
    if (!btn.dataset.armed) {
      btn.dataset.armed = '1';
      btn.style.color = '#ff726b';
      btn.title = 'Click again to delete';
      setTimeout(() => { delete btn.dataset.armed; btn.style.color = ''; btn.title = 'Delete'; }, 3000);
      return;
    }
    try {
      await s3(`s3 -X DELETE "$EP/$B/${enc(o.key)}"`);
      objects = objects.filter((x) => x !== o);
      render();
      status(`Deleted ${displayName(o.key)}`, 'good');
    } catch (e) {
      status(`Delete failed: ${e.message}`, 'bad');
    }
  }

  // Same key shape as BucketDrop: 8 random hex chars + "-" + filename.
  async function upload(paths) {
    if (!paths.length) return;
    if (!cfg) await loadConfig();
    const links = [];
    for (const [i, path] of paths.entries()) {
      const name = path.split('/').pop();
      const key = `${crypto.randomUUID().replace(/-/g, '').slice(0, 8).toUpperCase()}-${name}`;
      const label = paths.length > 1 ? `Uploading ${i + 1}/${paths.length} · ${name}` : `Uploading ${name}`;
      status(label, 'busy');
      nook.activity.set({ text: 'Uploading…', symbol: 'arrow.up.circle', color: '#ff9f0a' });
      try {
        await s3(`f=${q(path)}; s3 -H "Content-Type: $(file -b --mime-type "$f")" -T "$f" "$EP/$B/${enc(key)}"`);
        links.push(publicUrl(key));
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

  // Clipboard: a copied file (Finder) wins; otherwise a copied image is saved as PNG.
  async function pasteUpload() {
    const r = await nook.shell(`p=$(osascript -e 'POSIX path of (the clipboard as «class furl»)' 2>/dev/null) && { echo "$p"; exit; }
d=$(mktemp -d /tmp/nook-bucketdrop.XXXXXX); f="$d/Clipboard $(date +%Y-%m-%d\\ at\\ %H.%M.%S).png"
osascript -e "set f to open for access POSIX file \\"$f\\" with write permission" -e 'write (the clipboard as «class PNGf») to f' -e 'close access f' >/dev/null 2>&1 && echo "$f"`);
    const path = r.stdout.trim();
    if (!path) return status('Nothing to upload. Copy a file or an image first.', 'bad');
    upload([path]);
  }

  // Dropped files come in as File objects (no path), so write them to a temp file first.
  async function saveDropped(file) {
    const dir = (await nook.shell('mktemp -d /tmp/nook-bucketdrop.XXXXXX')).stdout.trim();
    const path = `${dir}/${file.name.replace(/\//g, ':')}`;
    const bytes = new Uint8Array(await file.arrayBuffer());
    const CHUNK = 300000; // multiple of 3, so each base64 piece decodes on its own
    await nook.shell(`: > ${q(path)}`);
    for (let i = 0; i < bytes.length; i += CHUNK) {
      let bin = '';
      const part = bytes.subarray(i, i + CHUNK);
      for (let j = 0; j < part.length; j += 8192) bin += String.fromCharCode(...part.subarray(j, j + 8192));
      await nook.shell(`printf %s '${btoa(bin)}' | base64 -D >> ${q(path)}`);
    }
    return path;
  }

  let dragDepth = 0;
  document.addEventListener('dragenter', (e) => { e.preventDefault(); dragDepth++; ui.drop.hidden = false; });
  document.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; ui.drop.hidden = true; } });
  document.addEventListener('dragover', (e) => e.preventDefault());
  document.addEventListener('drop', async (e) => {
    e.preventDefault();
    dragDepth = 0;
    ui.drop.hidden = true;
    const files = [...e.dataTransfer.files];
    if (!files.length) return;
    status(`Preparing ${files.length > 1 ? `${files.length} files` : files[0].name}…`, 'busy');
    try {
      upload(await Promise.all(files.map(saveDropped)));
    } catch (err) {
      status(`Could not read the file: ${err.message}`, 'bad');
    }
  });

  ui.pick.onclick = pick;
  ui.paste.onclick = pasteUpload;
  ui.refresh.onclick = refresh;
  ui.q.oninput = render;
  nook.on('show', refresh);
  refresh();
})();
