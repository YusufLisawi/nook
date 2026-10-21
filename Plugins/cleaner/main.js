const $ = (id) => document.getElementById(id);
const DEFAULTS = { downloadsDays: 60, includeDownloads: false, includeDeviceSupport: true };
const CATEGORIES = [
  { id: 'caches', name: 'User caches', icon: 'cache', description: 'App caches · excludes Apple and package caches' },
  { id: 'logs', name: 'Logs', icon: 'log', description: 'App logs in your Library' },
  { id: 'derived', name: 'Xcode DerivedData', icon: 'code', description: 'Build files · Xcode rebuilds them when needed' },
  { id: 'devices', name: 'iOS DeviceSupport', icon: 'phone', description: 'Xcode device files · downloaded again when needed' },
  { id: 'simulators', name: 'Simulator caches', icon: 'phone', description: 'CoreSimulator caches · keeps your simulators' },
  { id: 'packages', name: 'Package caches', icon: 'package', description: 'Downloaded packages · keeps the cache folders' },
  { id: 'brew', name: 'Homebrew', icon: 'brew', description: 'Cache estimate · cleans old versions and downloads' },
  { id: 'downloads', name: 'Old downloads', icon: 'download', description: '' },
  { id: 'trash', name: 'Trash', icon: 'trash', description: 'Empty all Trash with Finder · confirmation required' },
];
const records = new Map(CATEGORIES.map(({ id }) => [id, { bytes: null, count: 0, parts: [], available: true, skipped: 0, protectedCount: 0, unknown: false, status: 'idle', error: '' }]));
const selected = new Set(['caches', 'logs', 'derived', 'devices', 'simulators', 'packages', 'brew']);
const errors = new Map();
let settings = { ...DEFAULTS };
let settingsRevision = 0;
let settingsEvents = 0;
let settingsLoaded = false;
let busy = 'loading';
let initialized = false;
let visible = true; // Native creates this webview lazily, when first shown.
let scanAgain = false;
let lastScanned = 0;
let confirmation = null;
let home = '';
let outcome = null;

function errorMessage(error) { return String(error?.message || error || 'Something went wrong.').slice(0, 500); }

function showError(key, error) {
  if (error) errors.set(key, errorMessage(error)); else errors.delete(key);
  $('error').textContent = Array.from(errors.values()).join(' ');
  $('error').hidden = errors.size === 0;
}

function rowError(id, message) {
  records.get(id).error = errorMessage(message);
  records.get(id).status = 'error';
  render();
}

function size(bytes) {
  if (!Number.isFinite(bytes)) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let amount = Math.max(0, bytes), unit = 0;
  while (amount >= 1000 && unit < units.length - 1) { amount /= 1000; unit++; }
  return `${amount.toLocaleString(undefined, { maximumFractionDigits: unit && amount < 100 ? 1 : 0 })} ${units[unit]}`;
}

function ago(timestamp) {
  const minutes = Math.max(0, Math.floor((Date.now() - timestamp) / 60000));
  if (!minutes) return 'Scanned just now';
  if (minutes < 60) return `Scanned ${minutes} min ago`;
  if (minutes < 1440) return `Scanned ${Math.floor(minutes / 60)} hr ago`;
  return `Scanned ${Math.floor(minutes / 1440)} days ago`;
}

function enabled(id) {
  return (id !== 'downloads' || settings.includeDownloads) && (id !== 'devices' || settings.includeDeviceSupport);
}

function fingerprint(value = settings) {
  return `${value.downloadsDays}:${value.includeDownloads}:${value.includeDeviceSupport}`;
}

function chosen() {
  return CATEGORIES.filter(({ id }) => {
    const record = records.get(id);
    return selected.has(id) && enabled(id) && record.available && !record.error
      && ((id === 'trash' && record.unknown) || (Number.isFinite(record.bytes)
        && (record.bytes > 0 || record.count > 0 || id === 'brew')));
  });
}

function icon(name, extra = '') {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', `icon ${extra}`);
  svg.setAttribute('aria-hidden', 'true');
  const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
  use.setAttribute('href', `#i-${name}`);
  svg.append(use);
  return svg;
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function categoryRow(category) {
  const { id, name } = category;
  const record = records.get(id);
  const active = enabled(id);
  const row = element('div', `nk-item category${active && record.available ? '' : ' disabled-category'}`);
  row.dataset.category = id;
  const check = element('input', 'category-check');
  check.type = 'checkbox';
  check.id = `select-${id}`;
  check.checked = selected.has(id) && active;
  check.disabled = !active || !record.available || busy === 'cleaning' || busy === 'loading';
  check.setAttribute('aria-label', `Select ${name}`);
  check.addEventListener('change', () => {
    if (check.checked) selected.add(id); else selected.delete(id);
    cancelConfirmation();
    renderFooter();
  });

  const main = element('div', 'category-main');
  const title = element('div', 'category-title');
  const label = element('label', '', name);
  label.htmlFor = check.id;
  title.append(label);
  let description = category.description;
  if (id === 'downloads') description = `${record.bytes === null ? 'Files' : `${record.count} file${record.count === 1 ? '' : 's'}`} unchanged for ${settings.downloadsDays} days · files only`;
  if (!active) description = 'Enable in this plugin’s settings';
  if (!record.available) description = record.note || 'Not available';
  if (active && record.skipped) description = skippedMessage(record.skipped, record.protectedCount);
  main.append(title, element('span', 'category-description nk-small nk-muted nk-ellipsis', description));

  const amount = element('span', 'category-size nk-small nk-num');
  if (['measuring', 'cleaning', 'queued'].includes(record.status)) {
    const spinner = element('span', 'nk-spinner');
    spinner.setAttribute('aria-label', record.status === 'measuring' ? 'Measuring' : record.status === 'queued' ? 'Queued' : 'Cleaning');
    amount.append(spinner);
  } else if (record.status === 'done') amount.append(icon('check', 'done'));
  amount.append(element('span', '', !active || !record.available ? '—' : record.status === 'cleaning' ? 'Cleaning…' : record.unknown ? 'Size unknown' : size(record.bytes)));
  row.append(check, icon(category.icon, 'category-icon'), main, amount);

  if (id === 'packages' && record.parts.length && active) {
    const parts = element('div', 'category-parts nk-small nk-muted');
    for (const part of record.parts) {
      const line = element('div', 'package-part');
      line.append(element('span', '', part.name), element('span', 'nk-num', size(part.bytes)));
      parts.append(line);
    }
    row.append(parts);
  }
  if (record.error) {
    const failure = element('div', 'nk-error category-error', record.error);
    failure.setAttribute('role', 'alert');
    row.append(failure);
  }
  return row;
}

function renderFooter() {
  const items = chosen();
  const total = items.reduce((sum, { id }) => sum + (records.get(id).bytes || 0), 0);
  const unknownTrash = items.some(({ id }) => id === 'trash' && records.get(id).unknown);
  $('clean-label').textContent = busy === 'cleaning' ? 'Cleaning…'
    : unknownTrash && items.length === 1 ? 'Empty Trash' : `Clean ${size(total)}${unknownTrash ? ' + Trash' : ''}`;
  $('clean').disabled = Boolean(busy) || !settingsLoaded || items.length === 0;
  $('scan').disabled = Boolean(busy);
  $('scan').textContent = busy === 'scanning' ? 'Scanning…' : 'Scan';
  const selectionSize = unknownTrash ? (items.length === 1 ? 'Trash size unknown' : `${size(total)} + Trash size unknown`) : `${size(total)} selected`;
  $('selected').textContent = busy === 'cleaning' ? 'Moving items safely…'
    : `${selectionSize} · ${items.length} categor${items.length === 1 ? 'y' : 'ies'}`;
  $('scanned').textContent = busy === 'scanning' ? 'Measuring folders…' : lastScanned ? ago(lastScanned) : 'Not scanned yet';
  $('footer').hidden = Boolean(confirmation);
  $('confirmation').hidden = !confirmation;
}

function render() {
  const list = $('categories');
  const scroll = list.scrollTop;
  const focused = document.activeElement?.id;
  list.replaceChildren(...CATEGORIES.map(categoryRow));
  list.scrollTop = scroll;
  if (focused?.startsWith('select-')) $(focused)?.focus({ preventScroll: true });
  const allEmpty = !busy && lastScanned && CATEGORIES.filter(({ id }) => enabled(id)).every(({ id }) => {
    const record = records.get(id);
    return !record.error && record.bytes === 0 && record.count === 0 && !(id === 'brew' && record.available);
  });
  $('loading').hidden = busy !== 'loading';
  list.hidden = busy === 'loading' || Boolean(allEmpty);
  $('empty').hidden = !allEmpty;
  $('privacy-hint').hidden = !Array.from(records).some(([id, record]) => enabled(id) && record.protectedCount > 0) && !outcome?.protectedCount;
  renderFooter();
}

function skippedMessage(count, protectedCount) {
  return `${count} item${count === 1 ? '' : 's'} skipped${protectedCount === count ? ' — protected by macOS'
    : protectedCount ? ` · ${protectedCount} protected by macOS` : ' — kept in place for safety'}`;
}

async function shell(command, id, context) {
  try {
    const response = await nook.shell(command, { timeout: 120 });
    if (!response || response.code !== 0) {
      const message = response?.stderr?.trim() || `${context} failed or timed out. Try Scan again.`;
      if (id === 'trash' && /(-1743|not authorized|not permitted to send Apple events)/i.test(message)) {
        throw new Error('Allow Nook to control Finder in System Settings → Privacy & Security → Automation, then retry.');
      }
      throw new Error(message);
    }
    if (id) records.get(id).error = '';
    return response;
  } catch (error) {
    if (id) rowError(id, `${context}: ${errorMessage(error)}`);
    else showError('shell', `${context}: ${errorMessage(error)}`);
    throw error;
  }
}

async function refreshDisk() {
  try {
    const { disk } = await nook.system();
    if (!disk || !Number.isFinite(disk.total) || disk.total <= 0 || !Number.isFinite(disk.free)) throw new Error('Disk size is unavailable. Try Scan again.');
    const used = Math.max(0, Math.min(100, (1 - disk.free / disk.total) * 100));
    $('disk-free').textContent = size(disk.free);
    $('disk-total').textContent = `free of ${size(disk.total)}`;
    $('disk-used').style.width = `${used}%`;
    $('disk-progress').setAttribute('aria-valuenow', String(Math.round(used)));
    showError('disk', null);
  } catch (error) {
    $('disk-total').textContent = 'Disk unavailable';
    showError('disk', `Couldn’t read disk space: ${errorMessage(error)}`);
  }
}

function parseMeasurement(stdout) {
  const lines = stdout.trim().split('\n').map((line) => line.split('\t'));
  const integer = (value) => /^\d+$/.test(value || '') && Number.isSafeInteger(Number(value));
  const base = { bytes: 0, count: 0, parts: [], available: true, unknown: false, skipped: 0, protectedCount: 0 };
  const unavailable = lines.find(([kind]) => kind === 'UNAVAILABLE');
  if (unavailable) return { ...base, available: false, note: unavailable[1] };
  if (lines.some(([kind]) => kind === 'UNKNOWN')) return { ...base, bytes: null, unknown: true };
  const total = lines.find(([kind]) => kind === 'TOTAL');
  const skipped = lines.find(([kind]) => kind === 'SKIPPED');
  if (!total || !integer(total[1]) || !integer(total[2]) || !skipped || !integer(skipped[1]) || !integer(skipped[2])
      || Number(skipped[2]) > Number(skipped[1])) throw new Error('Could not read the scan result. Try Scan again.');
  const parts = lines.filter(([kind]) => kind === 'PART').map(([, name, bytes, count]) => {
    if (!integer(bytes) || !integer(count)) throw new Error('Incomplete package scan. Try Scan again.');
    return { name, bytes: Number(bytes), count: Number(count) };
  });
  return { ...base, bytes: Number(total[1]), count: Number(total[2]), parts,
    skipped: Number(skipped[1]), protectedCount: Number(skipped[2]) };
}

async function measure(id, scanSettings) {
  const record = records.get(id);
  record.status = 'measuring';
  record.error = '';
  render();
  try {
    const response = await shell(CleanerShell.scan(id, scanSettings.downloadsDays), id, 'Couldn’t measure this folder');
    Object.assign(record, parseMeasurement(response.stdout), { status: 'ready', error: '' });
  } catch (error) {
    rowError(id, error);
  }
  render();
}

// One scan at a time; each worker's shell script runs its du calls serially.
async function scan() {
  if (busy) { scanAgain = true; return; }
  busy = 'scanning';
  if (!settingsLoaded) await readSettings();
  scanAgain = false;
  cancelConfirmation();
  const revision = settingsRevision;
  const scanSettings = { ...settings };
  const queue = CATEGORIES.filter(({ id }) => enabled(id)).map(({ id }) => id);
  for (const id of queue) records.get(id).status = 'measuring';
  render();
  const disk = refreshDisk();
  const worker = async () => {
    while (queue.length) await measure(queue.shift(), scanSettings);
  };
  await Promise.all([worker(), worker(), worker(), disk]);
  lastScanned = Date.now();
  if (revision === settingsRevision) {
    try {
      await nook.storage.set('scan', {
        version: 2, at: lastScanned, settings: fingerprint(scanSettings),
        categories: Object.fromEntries(Array.from(records, ([id, record]) => [id, {
          bytes: record.bytes, count: record.count, parts: record.parts, available: record.available,
          note: record.note || '', error: record.error, skipped: record.skipped, protectedCount: record.protectedCount, unknown: record.unknown,
        }])),
      });
      showError('cache', null);
    } catch (error) { showError('cache', `Couldn’t save this scan: ${errorMessage(error)}`); }
  }
  busy = '';
  render();
  if (scanAgain || revision !== settingsRevision) { scanAgain = false; await scan(); }
}

function cancelConfirmation() { confirmation = null; renderFooter(); }

function askToClean() {
  if (busy || !settingsLoaded) return;
  const items = chosen();
  if (!items.length) return;
  const ids = items.map(({ id }) => id);
  const moving = ids.some((id) => id !== 'trash' && id !== 'brew');
  const messages = [];
  if (ids.includes('trash')) messages.push('Permanently empty all existing Trash with Finder first?');
  if (moving) messages.push('Move the selected files to Trash?');
  if (ids.includes('brew')) messages.push('Homebrew will delete old versions and downloads.');
  confirmation = { ids, revision: settingsRevision, downloadsDays: settings.downloadsDays };
  $('confirm-text').textContent = messages.join(' ');
  $('confirm-clean').textContent = ids.includes('trash') ? 'Empty & clean' : 'Clean';
  $('result').hidden = true;
  renderFooter();
  $('confirm-clean').focus();
}

function showOutcome() {
  if (!outcome) return;
  const messages = [];
  if (outcome.movedCount) messages.push(`Moved ${size(outcome.movedBytes)} to Trash`);
  if (outcome.emptied) messages.push('Previous Trash emptied');
  if (outcome.brew) messages.push('Homebrew cleaned');
  $('result-title').textContent = messages.join(' · ') || (outcome.failed ? 'Cleaning incomplete — check Trash' : 'No files moved');
  $('result-detail').textContent = outcome.failed
    ? 'Some items could not be cleaned. Check the rows; any moved files are in Trash.'
    : outcome.skipped ? `${skippedMessage(outcome.skipped, outcome.protectedCount)}. ${outcome.movedCount ? 'Moved files remain in Trash.' : 'Accessible folders are up to date.'}`
    : outcome.movedCount ? 'Space is freed when you empty the Trash.' : 'Folder sizes are up to date.';
  $('result').hidden = false;
}

async function clean() {
  if (!confirmation || busy || !settingsLoaded || confirmation.revision !== settingsRevision) return;
  const plan = confirmation;
  confirmation = null;
  busy = 'cleaning';
  outcome = { movedBytes: 0, movedCount: 0, failed: 0, skipped: 0, protectedCount: 0, emptied: false, brew: false };
  // Empty old Trash first. Newly moved items remain recoverable after this run.
  const ids = [...plan.ids].sort((a, b) => (a === 'trash' ? -1 : b === 'trash' ? 1 : 0));
  for (const id of ids) { records.get(id).status = 'queued'; records.get(id).error = ''; }
  render();
  for (const id of ids) {
    if (!enabled(id) || (id === 'downloads' && plan.downloadsDays !== settings.downloadsDays)) {
      records.get(id).status = 'idle';
      continue;
    }
    const record = records.get(id);
    record.status = 'cleaning';
    render();
    try {
      if (id === 'trash' || id === 'brew') {
        const response = await shell(CleanerShell.clean(id), id, 'Couldn’t finish cleaning');
        const marker = id === 'trash' ? 'EMPTIED' : 'BREW_DONE';
        if (!response.stdout.split('\n').includes(marker)) throw new Error('Cleanup result is unavailable. Check Trash, then scan again.');
        if (id === 'trash') outcome.emptied = true; else outcome.brew = true;
      } else {
        if (!nook.cleaner?.clean) throw new Error('Update Nook to clean files safely, then retry.');
        const result = await nook.cleaner.clean(id, plan.downloadsDays);
        if (!result || ['bytes', 'moved', 'skipped', 'protectedCount', 'failed'].some((key) => !Number.isSafeInteger(result[key]) || result[key] < 0)
            || result.protectedCount > result.skipped) throw new Error('Couldn’t verify all moves. Check Trash, then scan again.');
        outcome.movedBytes += result.bytes;
        outcome.movedCount += result.moved;
        outcome.skipped += result.skipped;
        outcome.protectedCount += result.protectedCount;
        if (result.failed) {
          outcome.failed += result.failed - 1; // Catch below counts this category's first failure.
          throw new Error(`${result.failed} item(s) could not be moved. They were left in place; scan to retry.`);
        }
      }
      record.status = 'done';
    } catch (error) {
      outcome.failed++;
      rowError(id, error);
      if (id === 'trash') {
        // Finder may still be emptying after a timeout. Do not add new items.
        for (const pending of ids) if (records.get(pending).status === 'queued') records.get(pending).status = 'idle';
        break;
      }
    }
    render();
  }
  // Preserve cleanup failures while remeasuring every category, including the new Trash size.
  const failures = new Map(Array.from(records).filter(([, record]) => record.error).map(([id, record]) => [id, record.error]));
  selected.delete('trash');
  busy = '';
  await scan();
  for (const [id, message] of failures) rowError(id, message);
  showOutcome();
  render();
}

async function openTrash() {
  try {
    if (!home) {
      const response = await shell('echo $HOME', null, 'Couldn’t find your home folder');
      home = response.stdout.replace(/\r?\n$/, '');
      if (!home.startsWith('/') || home === '/') throw new Error('Your home folder is unavailable.');
    }
    await nook.open(`${home}/.Trash`);
    showError('open', null);
  } catch (error) { showError('open', `Couldn’t open Trash: ${errorMessage(error)}`); }
}

async function openPrivacy() {
  try {
    await nook.open('x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles');
    showError('privacy', null);
  } catch (error) { showError('privacy', `Couldn’t open Full Disk Access: ${errorMessage(error)}`); }
}

function handleKey(event) {
  if (event.key === 'Escape' && confirmation) {
    event.preventDefault(); cancelConfirmation(); $('clean').focus(); return;
  }
  if (event.key === 'Enter' && event.metaKey) {
    event.preventDefault();
    if (confirmation) void clean(); else askToClean();
    return;
  }
  if (confirmation || !['ArrowDown', 'ArrowUp'].includes(event.key) || event.metaKey || event.altKey || event.ctrlKey) return;
  const checks = CATEGORIES.map(({ id }) => $(`select-${id}`)).filter((check) => check && !check.disabled);
  if (!checks.length) return;
  const index = checks.indexOf(document.activeElement);
  event.preventDefault();
  const next = index < 0 ? (event.key === 'ArrowDown' ? 0 : checks.length - 1)
    : (index + (event.key === 'ArrowDown' ? 1 : -1) + checks.length) % checks.length;
  checks[next].focus();
}

function applySettings(value = {}) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    settingsLoaded = false;
    showError('settings', 'Settings are unavailable. Try Scan again.');
    cancelConfirmation();
    return;
  }
  settingsLoaded = true;
  showError('settings', null);
  const previous = settings;
  settings = {
    downloadsDays: CleanerShell.days(value.downloadsDays ?? DEFAULTS.downloadsDays),
    includeDownloads: typeof value.includeDownloads === 'boolean' ? value.includeDownloads : DEFAULTS.includeDownloads,
    includeDeviceSupport: typeof value.includeDeviceSupport === 'boolean' ? value.includeDeviceSupport : DEFAULTS.includeDeviceSupport,
  };
  if (fingerprint(previous) !== fingerprint()) {
    settingsRevision++;
    cancelConfirmation();
    for (const [id, key] of [['downloads', 'includeDownloads'], ['devices', 'includeDeviceSupport']]) {
      if (settings[key] && !previous[key]) selected.add(id);
      if (!settings[key]) selected.delete(id);
    }
    if (settings.downloadsDays !== previous.downloadsDays) records.get('downloads').bytes = null;
    if (initialized) {
      scanAgain = true;
      if (!busy && visible) void scan();
    }
  }
  render();
}

async function readSettings() {
  const generation = settingsEvents;
  try {
    const value = await nook.settings.get();
    if (settingsEvents === generation) applySettings(value);
  } catch (error) {
    if (settingsEvents === generation) showError('settings', `Couldn’t read settings: ${errorMessage(error)}. Scan to retry.`);
  }
}

async function shown(tab) {
  visible = tab === 'cleaner' || tab == null;
  if (!visible || !initialized) return;
  renderFooter();
  if (scanAgain || !lastScanned) await scan();
  else await refreshDisk();
}

async function start() {
  $('scan').addEventListener('click', () => { outcome = null; $('result').hidden = true; void scan(); });
  $('clean').addEventListener('click', askToClean);
  $('confirm-clean').addEventListener('click', () => { void clean(); });
  $('cancel-clean').addEventListener('click', cancelConfirmation);
  $('open-trash').addEventListener('click', () => { void openTrash(); });
  $('open-privacy').addEventListener('click', () => { void openPrivacy(); });
  document.addEventListener('keydown', handleKey);
  for (const [event, callback] of [
    ['settings', (value) => { settingsEvents++; applySettings(value); }],
    ['show', shown], ['open', shown], ['close', () => { visible = false; }],
  ]) {
    try { await nook.on(event, callback); }
    catch (error) { showError(`event-${event}`, `Couldn’t listen for ${event}: ${errorMessage(error)}`); }
  }
  await readSettings();
  try {
    const cache = await nook.storage.get('scan');
    if (cache?.version === 2 && cache.settings === fingerprint() && Number.isFinite(cache.at) && cache.at > 0) {
      lastScanned = cache.at;
      for (const { id } of CATEGORIES) {
        const cached = cache.categories?.[id];
        if (cached && ((Number.isSafeInteger(cached.bytes) && cached.bytes >= 0) || (id === 'trash' && cached.bytes === null && cached.unknown === true)) && Number.isSafeInteger(cached.count) && cached.count >= 0) {
          Object.assign(records.get(id), {
            bytes: cached.bytes, count: cached.count, unknown: id === 'trash' && cached.unknown === true,
            skipped: Number.isSafeInteger(cached.skipped) && cached.skipped >= 0 ? cached.skipped : 0,
            protectedCount: Number.isSafeInteger(cached.protectedCount) && cached.protectedCount >= 0 && cached.protectedCount <= cached.skipped ? cached.protectedCount : 0, available: cached.available !== false,
            note: typeof cached.note === 'string' ? cached.note : '',
            parts: Array.isArray(cached.parts) ? cached.parts.filter((part) => typeof part.name === 'string' && Number.isSafeInteger(part.bytes) && part.bytes >= 0) : [],
            error: typeof cached.error === 'string' ? cached.error : '', status: 'ready',
          });
        }
      }
    }
  } catch (error) { showError('cache', `Couldn’t load your last scan: ${errorMessage(error)}`); }
  busy = '';
  initialized = true;
  render();
  await scan();
}

void start();
