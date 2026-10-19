(() => {
  'use strict';

  const byId = (id) => document.getElementById(id);
  const ui = {
    search: byId('search'), clearSearch: byId('clear-search'), list: byId('note-list'),
    listEmpty: byId('list-empty'), listTitle: byId('list-empty-title'), listHint: byId('list-empty-hint'),
    newNote: byId('new-note'), count: byId('note-count'), panel: byId('editor-panel'),
    editor: byId('editor'), date: byId('edited-date'), pin: byId('pin-note'), delete: byId('delete-note'),
    details: byId('editor-details'), words: byId('word-count'), save: byId('save-state'),
    saveLabel: byId('save-label'), confirm: byId('delete-confirm'), cancelDelete: byId('cancel-delete'),
    confirmDelete: byId('confirm-delete'), empty: byId('empty-state'), emptyTitle: byId('empty-title'),
    emptyDescription: byId('empty-description'), emptyNew: byId('empty-new-note'),
    error: byId('error-banner'), errorMessage: byId('error-message'), retry: byId('retry-button')
  };
  let notes = [];
  let selectedId = null;
  let deleteId = null;
  let ready = false;
  let loading = false;
  let saving = false;
  let saveFailed = false;
  let version = 0;
  let savedVersion = 0;
  let saveTimer = null;
  let errorKind = null;

  const makeId = () => globalThis.crypto?.randomUUID?.() || `note-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const selected = () => notes.find((note) => note.id === selectedId);
  const titleFor = (note) => note.text.split(/\r?\n/, 1)[0].trim() || 'New note';
  const wordCount = (text) => text.trim() ? text.trim().split(/\s+/).length : 0;
  const sorted = () => [...notes].sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.updatedAt - a.updatedAt || b.createdAt - a.createdAt);
  const visibleNotes = () => {
    const query = ui.search.value.trim().toLocaleLowerCase();
    return sorted().filter((note) => !query || note.text.toLocaleLowerCase().includes(query));
  };

  function relativeDate(timestamp) {
    const seconds = Math.max(0, (Date.now() - timestamp) / 1000);
    if (seconds < 60) return 'Just now';
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
    if (seconds < 172800) return 'Yesterday';
    if (seconds < 604800) return `${Math.floor(seconds / 86400)}d ago`;
    return new Date(timestamp).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  }

  function timestampFor(value, fallback) {
    const number = typeof value === 'number' ? value : Date.parse(value);
    return Number.isFinite(number) && number >= 0 && number <= 8640000000000000 ? number : fallback;
  }

  function normalizeNotes(stored) {
    if (stored == null) return [];
    const rows = Array.isArray(stored) ? stored : stored.notes;
    if (!Array.isArray(rows)) throw new Error('Unexpected notes format');
    const ids = new Set();
    return rows.map((row) => {
      if (!row || typeof row !== 'object' || (typeof row.text !== 'string' && typeof row.content !== 'string')) {
        throw new Error('Unexpected note format');
      }
      const id = typeof row.id === 'string' && row.id && !ids.has(row.id) ? row.id : makeId();
      ids.add(id);
      const createdAt = timestampFor(row.createdAt, Date.now());
      return {
        id, text: typeof row.text === 'string' ? row.text : row.content,
        pinned: row.pinned === true, createdAt,
        updatedAt: timestampFor(row.updatedAt, createdAt)
      };
    });
  }

  function showError(message, kind) {
    errorKind = kind;
    ui.errorMessage.textContent = message;
    ui.error.hidden = false;
  }

  function clearError(kind) {
    if (kind && errorKind !== kind) return;
    errorKind = null;
    ui.error.hidden = true;
  }

  function renderSaveState() {
    const state = saveFailed ? 'error' : saving ? 'saving' : savedVersion < version ? 'unsaved' : 'saved';
    ui.save.dataset.state = state;
    ui.saveLabel.textContent = { error: 'Not saved', saving: 'Saving…', unsaved: 'Unsaved', saved: 'Saved' }[state];
    ui.save.querySelector('use').setAttribute('href', saveFailed ? '#icon-alert' : '#icon-check');
    ui.retry.disabled = loading || saving;
  }

  function setDeleteConfirmation(id) {
    deleteId = id;
    ui.confirm.hidden = !id;
    ui.details.hidden = Boolean(id);
    ui.delete.setAttribute('aria-expanded', String(Boolean(id)));
  }

  function renderList() {
    const visible = visibleNotes();
    const fragment = document.createDocumentFragment();
    for (const note of visible) {
      const item = document.createElement('li');
      item.className = 'note-item';
      const button = document.createElement('button');
      button.className = 'note-button';
      button.type = 'button';
      button.dataset.noteId = note.id;
      button.setAttribute('aria-current', String(note.id === selectedId));
      button.setAttribute('aria-label', `${note.pinned ? 'Pinned, ' : ''}${titleFor(note)}, ${relativeDate(note.updatedAt)}`);
      const heading = document.createElement('span');
      heading.className = 'note-heading';
      if (note.pinned) {
        const pin = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        pin.setAttribute('class', 'icon note-pin');
        pin.setAttribute('aria-hidden', 'true');
        const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
        use.setAttribute('href', '#icon-pin');
        pin.append(use);
        heading.append(pin);
      }
      const title = document.createElement('span');
      title.className = 'note-title';
      title.textContent = titleFor(note);
      heading.append(title);
      const meta = document.createElement('span');
      meta.className = 'note-meta';
      const date = document.createElement('span');
      date.className = 'note-date';
      date.textContent = relativeDate(note.updatedAt);
      date.title = new Date(note.updatedAt).toLocaleString();
      const preview = document.createElement('span');
      preview.className = 'note-preview';
      preview.textContent = note.text.split(/\r?\n/).slice(1).join(' ').trim() || 'No additional text';
      meta.append(date, preview);
      button.append(heading, meta);
      item.append(button);
      fragment.append(item);
    }
    ui.list.replaceChildren(fragment);
    ui.listEmpty.hidden = visible.length > 0;
    ui.listTitle.textContent = !ready ? loading ? 'Loading notes…' : 'Notes unavailable' : notes.length ? 'No matching notes' : 'No notes yet';
    ui.listHint.textContent = !ready ? loading ? 'A moment for your thoughts.' : 'Try loading them again.' : notes.length ? 'Try another search.' : 'Start with a small thought.';
    ui.count.textContent = !ready || !notes.length ? '⌘N' : `${notes.length} ${notes.length === 1 ? 'note' : 'notes'}`;
    ui.clearSearch.hidden = !ui.search.value;
  }

  function renderEditor() {
    const note = selected();
    ui.panel.hidden = !note;
    ui.empty.hidden = Boolean(note);
    ui.editor.disabled = !ready || !note;
    if (note) {
      if (ui.editor.value !== note.text) ui.editor.value = note.text;
      ui.date.textContent = `Edited ${relativeDate(note.updatedAt).toLocaleLowerCase()}`;
      ui.date.title = new Date(note.updatedAt).toLocaleString();
      ui.pin.setAttribute('aria-pressed', String(note.pinned));
      ui.pin.setAttribute('aria-label', note.pinned ? 'Unpin note' : 'Pin note');
      ui.pin.title = note.pinned ? 'Unpin note' : 'Pin note';
      const count = wordCount(note.text);
      ui.words.textContent = `${count} ${count === 1 ? 'word' : 'words'}`;
    } else {
      ui.emptyTitle.textContent = !ready && !loading ? 'Notes couldn’t load' : notes.length ? 'No matching notes' : 'A place for your thoughts';
      ui.emptyDescription.textContent = !ready && !loading ? 'Try again to load your saved notes.' : notes.length ? 'Try another search, or start something new.' : 'Quick ideas. Little reminders. Always close.';
    }
    renderSaveState();
  }

  function renderAll() {
    ui.search.disabled = !ready;
    ui.newNote.disabled = !ready;
    ui.emptyNew.disabled = !ready;
    renderList();
    renderEditor();
  }

  async function loadNotes() {
    if (loading || ready) return;
    loading = true;
    renderAll();
    try {
      if (!window.nook?.storage?.get) throw new Error('Notes storage is unavailable');
      const stored = await window.nook.storage.get('notes');
      notes = normalizeNotes(stored);
      selectedId = sorted()[0]?.id || null;
      ready = true;
      clearError('load');
    } catch {
      showError('Your notes couldn’t load. Try again in a moment.', 'load');
    } finally {
      loading = false;
      renderAll();
    }
  }

  async function saveNotes() {
    clearTimeout(saveTimer);
    saveTimer = null;
    if (!ready || saving || savedVersion === version) return;
    saving = true;
    saveFailed = false;
    renderSaveState();
    try {
      while (savedVersion < version) {
        const writingVersion = version;
        const snapshot = notes.map((note) => ({ ...note }));
        try {
          if (!window.nook?.storage?.set) throw new Error('Notes storage is unavailable');
          await window.nook.storage.set('notes', snapshot);
          savedVersion = writingVersion;
          saveFailed = false;
          clearError('save');
        } catch {
          saveFailed = true;
          showError('This change hasn’t saved yet. Your text is still here.', 'save');
          break;
        }
      }
    } finally {
      saving = false;
      renderSaveState();
    }
  }

  function changed() {
    version += 1;
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => { void saveNotes(); }, 400);
    renderSaveState();
  }

  function selectNote(id, focusEditor = true) {
    if (!ready || !notes.some((note) => note.id === id)) return;
    selectedId = id;
    setDeleteConfirmation(null);
    renderAll();
    if (focusEditor) ui.editor.focus();
  }

  function revealSelectedNote() {
    const button = [...ui.list.querySelectorAll('[data-note-id]')].find((item) => item.dataset.noteId === selectedId);
    if (!button) return;
    const top = button.offsetTop;
    const bottom = top + button.offsetHeight;
    if (top < ui.list.scrollTop) ui.list.scrollTop = top;
    else if (bottom > ui.list.scrollTop + ui.list.clientHeight) ui.list.scrollTop = bottom - ui.list.clientHeight;
  }

  function createNote() {
    if (!ready) return;
    const now = Date.now();
    const note = { id: makeId(), text: '', pinned: false, createdAt: now, updatedAt: now };
    notes.push(note);
    selectedId = note.id;
    ui.search.value = '';
    setDeleteConfirmation(null);
    changed();
    renderAll();
    revealSelectedNote();
    ui.editor.focus();
  }

  ui.newNote.addEventListener('click', createNote);
  ui.emptyNew.addEventListener('click', createNote);
  ui.search.addEventListener('input', () => {
    setDeleteConfirmation(null);
    const visible = visibleNotes();
    if (!visible.some((note) => note.id === selectedId)) selectedId = visible[0]?.id || null;
    renderAll();
  });
  ui.clearSearch.addEventListener('click', () => {
    ui.search.value = '';
    if (!selectedId) selectedId = sorted()[0]?.id || null;
    renderAll();
    ui.search.focus();
  });
  ui.list.addEventListener('click', (event) => {
    const button = event.target.closest('[data-note-id]');
    if (button) selectNote(button.dataset.noteId);
  });
  ui.list.addEventListener('keydown', (event) => {
    if (!['ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) return;
    const button = event.target.closest('[data-note-id]');
    if (!button) return;
    const visible = visibleNotes();
    const current = visible.findIndex((note) => note.id === button.dataset.noteId);
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? visible.length - 1 : Math.max(0, Math.min(visible.length - 1, current + (event.key === 'ArrowDown' ? 1 : -1)));
    if (!visible[next]) return;
    event.preventDefault();
    selectNote(visible[next].id, false);
    const target = [...ui.list.querySelectorAll('[data-note-id]')].find((item) => item.dataset.noteId === visible[next].id);
    target?.focus();
  });
  ui.editor.addEventListener('input', () => {
    const note = selected();
    if (!ready || !note) return;
    note.text = ui.editor.value;
    note.updatedAt = Date.now();
    setDeleteConfirmation(null);
    changed();
    renderList();
    renderEditor();
  });
  ui.editor.addEventListener('blur', () => { void saveNotes(); });
  ui.pin.addEventListener('click', () => {
    const note = selected();
    if (!ready || !note) return;
    note.pinned = !note.pinned;
    setDeleteConfirmation(null);
    changed();
    renderAll();
    revealSelectedNote();
  });
  ui.delete.addEventListener('click', () => {
    if (!ready || !selected()) return;
    setDeleteConfirmation(selectedId);
    ui.cancelDelete.focus();
  });
  ui.cancelDelete.addEventListener('click', () => {
    setDeleteConfirmation(null);
    ui.delete.focus();
  });
  ui.confirmDelete.addEventListener('click', () => {
    if (!ready || !deleteId) return;
    const visible = visibleNotes();
    const index = visible.findIndex((note) => note.id === deleteId);
    notes = notes.filter((note) => note.id !== deleteId);
    const remaining = visibleNotes();
    selectedId = remaining[Math.max(0, Math.min(index, remaining.length - 1))]?.id || null;
    setDeleteConfirmation(null);
    changed();
    renderAll();
    if (selectedId) ui.editor.focus();
    else ui.emptyNew.focus();
  });
  ui.retry.addEventListener('click', () => {
    if (errorKind === 'load') void loadNotes();
    else void saveNotes();
  });
  document.addEventListener('keydown', (event) => {
    if (event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey && event.key.toLowerCase() === 'n') {
      event.preventDefault();
      if (!event.repeat) createNote();
    } else if (event.key === 'Escape' && deleteId) {
      event.preventDefault();
      setDeleteConfirmation(null);
      ui.delete.focus();
    }
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) void saveNotes();
  });
  window.addEventListener('pagehide', () => { void saveNotes(); });
  setInterval(() => {
    for (const button of ui.list.querySelectorAll('[data-note-id]')) {
      const note = notes.find((item) => item.id === button.dataset.noteId);
      if (!note) continue;
      button.querySelector('.note-date').textContent = relativeDate(note.updatedAt);
      button.setAttribute('aria-label', `${note.pinned ? 'Pinned, ' : ''}${titleFor(note)}, ${relativeDate(note.updatedAt)}`);
    }
    const note = selected();
    if (note) ui.date.textContent = `Edited ${relativeDate(note.updatedAt).toLocaleLowerCase()}`;
  }, 60000);

  void loadNotes();
})();
