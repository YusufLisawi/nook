(() => {
  /** Totals over finished dictations: talking time vs. typing the same words at 40 wpm. */
  function dictationStats(list) {
    let words = 0, seconds = 0;
    for (const e of list || []) {
      if (e.status !== 'done' || !e.text) continue;
      words += e.text.trim().split(/\s+/).filter(Boolean).length;
      seconds += Number(e.duration) || 0;
    }
    const savedSeconds = Math.max(0, (words / 40) * 60 - seconds);
    const fmt = (s) => s < 60 ? `${Math.round(s)}s` : s < 3600 ? `${Math.round(s / 60)} min` : `${Math.floor(s / 3600)}h ${Math.round((s % 3600) / 60)}m`;
    return { words, spoken: fmt(seconds), saved: fmt(savedSeconds) };
  }

  'use strict';
  const $ = id => document.getElementById(id);
  const SVG_NS = 'http://www.w3.org/2000/svg';
  let history = [];
  let historyLoaded = false;
  let state = null;
  let toggling = false;
  let clearing = false;
  let disposed = false;
  let stateBusy = false;
  let stateVersion = 0;
  let historyVersion = 0;
  let eventVersion = 0;
  const pendingRows = new Map();
  const rowErrors = new Map();
  const feedback = new Map();
  const feedbackTimers = new Map();
  const expanded = new Set();
  const issues = new Map();

  function icon(name) {
    const svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('class', 'icon');
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

  function issue(source, message) {
    if (message) issues.set(source, message); else issues.delete(source);
    $('error-card').hidden = issues.size === 0;
    $('error-text').textContent = [...issues.values()].at(-1) || '';
  }

  const text = value => typeof value === 'string' ? value : '';
  const shortcut = (key, fallback) => text(state?.[key]).trim() || fallback;

  function renderState() {
    const recording = !!state?.recording;
    const transcribing = !!state?.transcribing && !recording;
    const hold = shortcut('holdShortcut', '⌃⌥');
    const toggle = shortcut('toggleShortcut', '⌥Space');
    $('state-label').textContent = toggling ? recording ? 'Finishing recording…' : 'Starting microphone…' : !state ? 'Dictation status unavailable' : recording ? `Recording… · ${toggle} to stop` : transcribing ? `Transcribing… · Hold ${hold} to talk` : `Hold ${hold} to talk · ${toggle} to toggle`;
    $('state-pill').title = `Hold ${hold} to talk · ${toggle} to toggle`;
    $('mic-button').title = `Hold ${hold} to talk · ${toggle} to toggle`;
    $('state-pill').classList.toggle('recording', recording);
    $('state-pill').classList.toggle('transcribing', transcribing);
    $('state-icon').replaceChildren(transcribing || toggling ? spinner() : icon('wave'));
    $('mic-button').classList.toggle('recording', recording);
    $('mic-button').disabled = toggling || !state || state.hasKey === false;
    const micLabel = recording ? 'Stop dictation' : 'Start dictation';
    $('mic-button').setAttribute('aria-label', micLabel);
    $('mic-button').title = micLabel;
    $('mic-button').replaceChildren(toggling ? spinner() : icon(recording ? 'stop' : 'mic'));
    $('key-warning').hidden = state?.hasKey !== false;
    $('clear-button').disabled = !history.length || clearing || pendingRows.size > 0;
    $('confirm-clear').disabled = clearing || pendingRows.size > 0;
    $('cancel-clear').disabled = clearing;
    $('confirm-clear').textContent = clearing ? 'Clearing…' : 'Clear all';
  }

  function relativeTime(date) {
    const timestamp = Date.parse(date);
    if (!Number.isFinite(timestamp)) return 'Unknown time';
    const seconds = Math.max(0, (Date.now() - timestamp) / 1000);
    if (seconds < 60) return 'Just now';
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
    if (seconds < 604800) return `${Math.floor(seconds / 86400)}d ago`;
    return new Date(timestamp).toLocaleDateString(undefined, { month: 'short', day: 'numeric', ...(new Date(timestamp).getFullYear() !== new Date().getFullYear() ? { year: 'numeric' } : {}) });
  }

  function duration(value) {
    if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return null;
    if (value < 60) return `${Number(value.toFixed(1))}s`;
    const seconds = Math.round(value);
    return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  }

  function rowButton(entry, action, label, glyph, compact = false) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = compact ? 'icon-button delete' : `small-button ${action}`;
    button.dataset.entryId = entry.id;
    button.dataset.action = action;
    button.disabled = pendingRows.has(entry.id) || clearing;
    button.title = label;
    button.setAttribute('aria-label', `${label} dictation`);
    const busy = pendingRows.get(entry.id) === action;
    const success = feedback.get(entry.id) === action;
    button.append(busy ? spinner() : icon(success ? 'check' : glyph));
    if (!compact) {
      const copy = document.createElement('span');
      copy.textContent = busy ? action === 'retry' ? 'Retrying…' : label : success ? action === 'copy' ? 'Copied' : 'Pasted' : label;
      button.append(copy);
    }
    button.classList.toggle('success', success);
    button.addEventListener('click', () => { void rowAction(entry.id, action); });
    return button;
  }

  function buildRow(entry) {
    const row = document.createElement('article');
    row.className = `entry ${entry.status}${expanded.has(entry.id) ? ' expanded' : ''}`;
    row.dataset.entryId = entry.id;
    const transcript = text(entry.text) || text(entry.raw);
    if (entry.status === 'done') {
      const content = document.createElement('button');
      content.type = 'button';
      content.className = 'entry-text';
      content.textContent = transcript || 'No transcript was returned.';
      content.dataset.entryId = entry.id;
      content.dataset.action = 'expand';
      content.setAttribute('aria-expanded', String(expanded.has(entry.id)));
      content.setAttribute('aria-label', `${expanded.has(entry.id) ? 'Collapse' : 'Expand'} transcript: ${transcript}`);
      content.addEventListener('click', () => {
        if (window.getSelection()?.toString()) return;
        if (expanded.has(entry.id)) expanded.delete(entry.id); else expanded.add(entry.id);
        renderHistory();
      });
      row.append(content);
    } else {
      const status = document.createElement('div');
      status.className = 'entry-status';
      const label = document.createElement('span');
      label.textContent = entry.status === 'failed' ? 'Transcription failed' : 'Transcribing…';
      status.append(entry.status === 'failed' ? icon('warning') : spinner(), label);
      row.append(status);
      if (entry.status === 'failed') {
        const detail = document.createElement('button');
        detail.className = 'entry-text entry-error';
        detail.type = 'button';
        detail.textContent = text(entry.error) || 'Something interrupted this transcription. Try again.';
        detail.setAttribute('aria-expanded', String(expanded.has(entry.id)));
        detail.setAttribute('aria-label', 'Expand or collapse transcription error');
        detail.dataset.entryId = entry.id;
        detail.dataset.action = 'expand';
        detail.addEventListener('click', () => {
          if (expanded.has(entry.id)) expanded.delete(entry.id); else expanded.add(entry.id);
          renderHistory();
        });
        row.append(detail);
      }
    }
    const footer = document.createElement('div');
    footer.className = 'entry-footer';
    const meta = document.createElement('div');
    meta.className = 'entry-meta';
    const time = document.createElement('time');
    time.className = 'entry-time';
    time.dataset.date = text(entry.date);
    time.textContent = relativeTime(entry.date);
    if (Number.isFinite(Date.parse(entry.date))) {
      time.dateTime = entry.date;
      time.title = new Date(entry.date).toLocaleString();
    }
    meta.append(time);
    const length = duration(entry.duration);
    if (length) {
      const dot = document.createElement('span');
      dot.className = 'meta-dot';
      dot.textContent = '·';
      const elapsed = document.createElement('span');
      elapsed.textContent = length;
      elapsed.title = 'Recording duration';
      meta.append(dot, elapsed);
    }
    const actions = document.createElement('div');
    actions.className = 'entry-actions';
    if (entry.status === 'done') {
      const copy = rowButton(entry, 'copy', 'Copy', 'copy');
      const paste = rowButton(entry, 'paste', 'Paste', 'paste');
      if (!transcript) { copy.disabled = true; paste.disabled = true; }
      actions.append(copy, paste);
    } else if (entry.status === 'failed') actions.append(rowButton(entry, 'retry', 'Retry', 'retry'));
    actions.append(rowButton(entry, 'remove', 'Delete', 'trash', true));
    footer.append(meta, actions);
    row.append(footer);
    if (rowErrors.has(entry.id)) {
      const error = document.createElement('div');
      error.className = 'row-error';
      error.setAttribute('role', 'status');
      const message = document.createElement('span');
      message.textContent = rowErrors.get(entry.id);
      error.append(icon('warning'), message);
      row.append(error);
    }
    return row;
  }

  function renderHistory(resetScroll = false) {
    const list = $('history-list');
    const previousScroll = resetScroll ? 0 : list.scrollTop;
    const focused = list.contains(document.activeElement) ? {
      id: document.activeElement.dataset.entryId,
      action: document.activeElement.dataset.action
    } : null;
    const query = $('search').value.trim().toLocaleLowerCase();
    const entries = history.filter(entry => !query || [entry.text, entry.raw, entry.error].map(text).join(' ').toLocaleLowerCase().includes(query));
    const stats = dictationStats(history);
    $('history-count').textContent = !historyLoaded ? '—' : query ? `${entries.length} of ${history.length}` : (stats.words ? `${stats.spoken} spoken · ${stats.saved} saved` : `${history.length} ${history.length === 1 ? 'entry' : 'entries'}`);
    $('history-count').title = stats.words ? `${stats.words.toLocaleString()} words dictated. Saved = time to type them at 40 wpm minus time spent talking.` : '';
    const rows = entries.map(buildRow);
    if (!rows.length) {
      const empty = document.createElement('div');
      empty.className = 'empty-state';
      const title = document.createElement('strong');
      title.textContent = !historyLoaded ? 'History is unavailable' : query ? 'No matching dictations' : 'A little space for your thoughts';
      const hint = document.createElement('small');
      hint.textContent = !historyLoaded ? 'Use refresh above to try again.' : query ? 'Try a different word or clear your search.' : `Hold ${shortcut('holdShortcut', '⌃⌥')} to capture your first dictation.`;
      empty.append(icon(query ? 'search' : 'wave'), title, hint);
      rows.push(empty);
    }
    list.replaceChildren(...rows);
    list.scrollTop = previousScroll;
    if (focused?.id) {
      const replacement = [...list.querySelectorAll('button')].find(button => button.dataset.entryId === focused.id && button.dataset.action === focused.action);
      if (replacement && !replacement.disabled) replacement.focus({ preventScroll: true });
    }
    renderState();
  }

  function applyHistory(next) {
    if (!Array.isArray(next)) throw new Error('Invalid history');
    history = next.filter(entry => entry && typeof entry.id === 'string').map(entry => ({
      ...entry,
      status: ['done', 'failed', 'transcribing'].includes(entry.status) ? entry.status : 'failed'
    })).sort((a, b) => (Date.parse(b.date) || 0) - (Date.parse(a.date) || 0));
    historyLoaded = true;
    const ids = new Set(history.map(entry => entry.id));
    for (const id of expanded) if (!ids.has(id)) expanded.delete(id);
    for (const id of rowErrors.keys()) if (!ids.has(id)) rowErrors.delete(id);
    renderHistory();
  }

  async function refreshHistory() {
    const request = ++historyVersion;
    const events = eventVersion;
    try {
      if (!window.nook?.dictation?.history) throw new Error('Bridge unavailable');
      const next = await window.nook.dictation.history();
      if (disposed || request !== historyVersion || events !== eventVersion) return;
      applyHistory(next);
      issue('history', null);
    } catch (_) {
      if (request !== historyVersion || disposed) return;
      issue('history', 'Can’t load dictation history. Tap refresh to retry.');
      renderHistory();
    }
  }

  async function refreshState(force = false) {
    if (disposed || (!force && (stateBusy || toggling))) return;
    const request = ++stateVersion;
    stateBusy = true;
    try {
      if (!window.nook?.dictation?.state) throw new Error('Bridge unavailable');
      const next = await window.nook.dictation.state();
      if (request !== stateVersion || disposed) return;
      if (!next || typeof next.recording !== 'boolean') throw new Error('Invalid state');
      state = next;
      issue('state', null);
      renderState();
    } catch (_) {
      if (request === stateVersion && !disposed) {
        issue('state', 'Can’t check the microphone. Retrying…');
        renderState();
      }
    } finally { if (request === stateVersion) stateBusy = false; }
  }

  async function toggleDictation() {
    if (toggling || !state || state.hasKey === false) return;
    toggling = true;
    stateVersion += 1;
    issue('toggle', null);
    renderState();
    try {
      if (!window.nook?.dictation?.toggle) throw new Error('Bridge unavailable');
      await window.nook.dictation.toggle();
    } catch (_) { issue('toggle', 'Couldn’t toggle recording. Check microphone access in System Settings.'); }
    finally {
      await refreshState(true);
      toggling = false;
      renderState();
    }
  }

  async function rowAction(id, action) {
    if (pendingRows.has(id) || clearing || disposed) return;
    pendingRows.set(id, action);
    rowErrors.delete(id);
    feedback.delete(id);
    clearTimeout(feedbackTimers.get(id));
    renderHistory();
    try {
      if (!window.nook?.dictation) throw new Error('Bridge unavailable');
      if (action === 'copy') await window.nook.dictation.copy(id);
      else if (action === 'paste') await window.nook.dictation.paste(id);
      else if (action === 'retry') await window.nook.dictation.retry(id);
      else if (action === 'remove') await window.nook.dictation.remove(id);
      if (action === 'copy' || action === 'paste') {
        feedback.set(id, action);
        feedbackTimers.set(id, setTimeout(() => { feedback.delete(id); feedbackTimers.delete(id); if (!disposed) renderHistory(); }, 1800));
      } else {
        await refreshHistory();
        if (action === 'retry') await refreshState();
      }
    } catch (_) {
      const messages = {
        copy: 'Couldn’t copy this dictation. Try again.',
        paste: 'Couldn’t paste. Check Accessibility access in System Settings.',
        retry: 'Couldn’t retry. Check your API key and try again.',
        remove: 'Couldn’t delete this dictation. Try again.'
      };
      rowErrors.set(id, messages[action] || 'Something went wrong. Try again.');
    } finally {
      pendingRows.delete(id);
      if (!disposed) renderHistory();
    }
  }

  async function clearHistory() {
    if (clearing || pendingRows.size || $('clear-confirm').hidden) return;
    clearing = true;
    issue('clear', null);
    renderHistory();
    try {
      if (!window.nook?.dictation?.clear) throw new Error('Bridge unavailable');
      await window.nook.dictation.clear();
      $('clear-confirm').hidden = true;
      expanded.clear();
      rowErrors.clear();
      await refreshHistory();
    } catch (_) { issue('clear', 'Couldn’t clear history. Please try again.'); }
    finally { clearing = false; renderHistory(); }
  }

  $('mic-button').addEventListener('click', () => { void toggleDictation(); });
  $('search').addEventListener('input', () => renderHistory(true));
  $('clear-button').addEventListener('click', () => { $('clear-confirm').hidden = false; $('cancel-clear').focus(); });
  $('cancel-clear').addEventListener('click', () => { $('clear-confirm').hidden = true; $('clear-button').focus(); });
  $('confirm-clear').addEventListener('click', () => { void clearHistory(); });
  $('retry-load').addEventListener('click', async () => { await refreshState(); await refreshHistory(); });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !clearing && !$('clear-confirm').hidden) { $('clear-confirm').hidden = true; $('clear-button').focus(); }
  });

  async function start() {
    try {
      if (!window.nook?.on) throw new Error('Bridge unavailable');
      await window.nook.on('dictation', next => {
        if (disposed) return;
        try { eventVersion += 1; applyHistory(next); issue('history', null); }
        catch (_) { issue('history', 'Couldn’t update history. Tap refresh to sync.'); }
        void refreshState();
      });
    } catch (_) { issue('subscription', 'Live history updates are unavailable. Tap refresh to sync.'); }
    await refreshState();
    await refreshHistory();
  }
  const stateTimer = setInterval(() => { void refreshState(); }, 1000);
  const timeTimer = setInterval(() => {
    for (const node of document.querySelectorAll('.entry-time')) node.textContent = relativeTime(node.dataset.date);
  }, 30000);
  window.addEventListener('pagehide', () => {
    disposed = true;
    clearInterval(stateTimer);
    clearInterval(timeTimer);
    for (const timer of feedbackTimers.values()) clearTimeout(timer);
  }, { once: true });
  void start();
})();
