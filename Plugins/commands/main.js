(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const outputs = { replace: 'Replace', paste: 'Paste', copy: 'Copy', notch: 'Notch' };
  const emojis = [
    ['✨', 'Sparkles'], ['✍️', 'Writing'], ['📝', 'Note'], ['💬', 'Message'], ['🪄', 'Magic wand'], ['🧠', 'Brain'], ['💡', 'Idea'], ['🔍', 'Search'],
    ['📋', 'Clipboard'], ['📄', 'Document'], ['📚', 'Books'], ['📖', 'Reading'], ['🔖', 'Bookmark'], ['🗂️', 'Files'], ['📌', 'Pin'], ['🎯', 'Target'],
    ['🌍', 'Globe'], ['🔤', 'Letters'], ['🗣️', 'Speech'], ['💻', 'Computer'], ['🛠️', 'Tools'], ['🧩', 'Puzzle'], ['⚡', 'Lightning'], ['🔧', 'Wrench'],
    ['✅', 'Check'], ['🧹', 'Clean up'], ['✂️', 'Scissors'], ['📏', 'Ruler'], ['🎨', 'Palette'], ['🎵', 'Music'], ['📊', 'Chart'], ['🧮', 'Calculator'],
    ['📅', 'Calendar'], ['⏱️', 'Timer'], ['📨', 'Mail'], ['🤝', 'Handshake'], ['💼', 'Briefcase'], ['🛡️', 'Shield'], ['🔬', 'Research'], ['🌱', 'Seedling'],
  ];
  let commands = [], providers = [];
  let loaded = false, loading = true, listRevision = 0, listRead = 0;
  let catalogReady = false, catalogLoading = false, catalogError = '', catalogRead = 0;
  let draft = null, busy = '', confirmingDelete = false, returnCommandId = null;
  let notice = null, latestRun = null, panelRun = null, panelOpen = false;
  let runRevision = 0, lastRunRead = 0, dismissRevision = 0, localRun = 0;
  let copying = false, copiedRun = null, copyTimer;
  const pendingRuns = new Map(), subscriptions = new Set(), dismissedRuns = new Map();
  const activeRuns = new Map(), runStatuses = new Map();

  const messageOf = (error) => String(error?.message || error || 'Please try again.');
  const findCommand = (id) => commands.find((command) => command.id === id);
  const cloneHotkey = (hotkey) => hotkey?.display ? { display: String(hotkey.display) } : null;
  const node = (tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  };
  function icon(name) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('class', 'icon');
    svg.setAttribute('aria-hidden', 'true');
    const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', `#i-${name}`);
    svg.append(use);
    return svg;
  }
  function button(label, className, action) {
    const element = node('button', className, label);
    element.type = 'button';
    element.onclick = action;
    return element;
  }
  function deckError(scope, text, retry) {
    notice = { scope, text, retry };
    $('deck-error-text').textContent = text;
    $('deck-error-text').title = text;
    $('deck-retry').hidden = !retry;
    $('deck-error').hidden = false;
  }
  function clearDeckError(scope) {
    if (scope && notice?.scope !== scope) return;
    notice = null;
    $('deck-error').hidden = true;
  }
  function editorError(text = '', field) {
    $('editor-error').textContent = text;
    $('editor-error').hidden = !text;
    if (text) $('editor-error').scrollIntoView({ block: 'nearest' });
    if (field) { field.setAttribute('aria-invalid', 'true'); field.focus(); }
  }
  function applyViews() {
    $('deck').hidden = !!draft;
    $('editor').hidden = !draft;
    $('result').hidden = !panelOpen;
    $('app').classList.toggle('has-result', panelOpen);
    for (const id of ['deck', 'editor']) {
      $(id).inert = panelOpen;
      if (panelOpen) $(id).setAttribute('aria-hidden', 'true');
      else $(id).removeAttribute('aria-hidden');
    }
  }
  function focusView() {
    if (panelOpen) $('close-result').focus({ preventScroll: true });
    else if (draft) $('command-name').focus({ preventScroll: true });
    else {
      const card = [...$('command-grid').children].find((item) => item.dataset.commandId === returnCommandId);
      (card?.querySelector('.card-edit') || $('search')).focus({ preventScroll: true });
    }
  }

  function checkList(value) {
    if (!Array.isArray(value) || value.some((item) => !item || typeof item.id !== 'string')) {
      throw new Error('Unexpected command list. Try again.');
    }
    return value;
  }
  function acceptCommands(value) {
    commands = checkList(value).map((command) => ({ ...command, hotkey: cloneHotkey(command.hotkey) }));
    listRevision += 1;
    loaded = true;
    loading = false;
    clearDeckError('list');
    // Native hotkey changes are already saved. Preserve all other draft fields.
    if (draft?.id) {
      const saved = findCommand(draft.id);
      if (saved) draft.hotkey = cloneHotkey(saved.hotkey);
      else if (busy !== 'delete') editorError('This command was removed. Duplicate it to keep your edits.');
    }
    renderDeck();
    renderEditorState();
    renderResultControls();
  }
  async function refreshCommands() {
    const request = ++listRead, revision = listRevision;
    if (!loaded) { loading = true; renderDeck(); }
    try {
      const list = await window.nook.commands.list();
      if (request === listRead && revision === listRevision) acceptCommands(list);
    } catch (error) {
      if (request !== listRead || revision !== listRevision) return;
      loading = false;
      deckError('list', `Couldn't load commands. ${messageOf(error)}`, refreshCommands);
      renderDeck();
    }
  }
  async function acceptMutation(list, revision) {
    checkList(list);
    if (revision === listRevision) acceptCommands(list);
    // A native event may be newer than this response. Read back instead of undoing it.
    else await refreshCommands();
  }
  function isRunning(id) {
    return pendingRuns.has(id) || activeRuns.has(id);
  }
  function renderDeck() {
    const grid = $('command-grid');
    const active = document.activeElement;
    const focusedId = active?.closest('.command-card')?.dataset.commandId;
    const focusedKind = active?.dataset.kind;
    const scrollTop = grid.scrollTop;
    const query = $('search').value.trim().toLocaleLowerCase();
    const visible = commands.filter((command) => String(command.name || '').toLocaleLowerCase().includes(query));
    $('deck-loading').hidden = loaded || !loading;
    $('deck-empty').hidden = (!loaded && loading) || visible.length > 0;
    grid.hidden = visible.length === 0;
    if (!visible.length) {
      const failed = !loaded && !loading;
      $('empty-title').textContent = failed ? 'Commands unavailable' : query ? 'No matching commands' : 'No commands yet';
      $('empty-hint').textContent = failed ? 'Try loading your commands again.' : query ? 'Try another name, or create a new command.' : 'Create a command for the things you write every day.';
      $('empty-icon').setAttribute('href', query ? '#i-search' : '#i-wand');
      $('empty-action').textContent = failed ? 'Try again' : query ? 'Clear search' : 'Create command';
      $('empty-action').onclick = failed ? refreshCommands : query ? () => { $('search').value = ''; renderDeck(); $('search').focus(); } : () => openEditor();
    }
    const fragment = document.createDocumentFragment();
    for (const command of visible) {
      const running = isRunning(command.id);
      const card = node('div', `command-card nk-card nk-hover${command.enabled === false ? ' is-disabled' : ''}`);
      card.dataset.commandId = command.id;
      card.setAttribute('role', 'listitem');
      const run = button('', 'command-run', () => runCommand(command.id));
      run.dataset.kind = 'run';
      run.setAttribute('aria-label', `${running ? 'Running' : 'Run'} ${command.name || 'Untitled command'}${command.enabled === false ? ' (disabled)' : ''}`);
      run.setAttribute('aria-disabled', String(command.enabled === false || running));
      run.title = command.enabled === false ? 'Disabled. Edit this command to enable it.' : String(command.name || 'Run command');
      const heading = node('span', 'card-heading nk-row-flex');
      const tile = node('span', 'emoji-tile', command.icon || '✨');
      tile.setAttribute('aria-hidden', 'true');
      heading.append(tile, node('span', 'command-name', command.name || 'Untitled command'));
      const meta = node('span', 'card-meta nk-row-flex');
      if (running) {
        const label = node('span', 'card-running nk-row-flex');
        label.append(node('span', 'nk-spinner'), node('span', '', 'Running…'));
        meta.append(label);
      } else {
        const hotkey = node(command.hotkey ? 'kbd' : 'span', command.hotkey ? 'hotkey-chip nk-ellipsis' : 'no-hotkey nk-muted', command.hotkey?.display || 'No hotkey');
        hotkey.title = command.hotkey?.display || 'No hotkey';
        meta.append(hotkey);
      }
      meta.append(node('span', 'output-badge nk-pill', outputs[command.output] || 'Replace'));
      run.append(heading, meta);
      const edit = button('', 'card-edit nk-icon-btn', () => openEditor(findCommand(command.id)));
      edit.dataset.kind = 'edit';
      edit.title = `Edit ${command.name || 'command'}`;
      edit.setAttribute('aria-label', edit.title);
      edit.append(icon('edit'));
      card.append(run, edit);
      fragment.append(card);
    }
    grid.replaceChildren(fragment);
    grid.scrollTop = scrollTop;
    if (focusedId && !draft && !panelOpen) {
      const card = [...grid.children].find((item) => item.dataset.commandId === focusedId);
      card?.querySelector(focusedKind === 'edit' ? '.card-edit' : '.command-run')?.focus({ preventScroll: true });
    }
  }

  async function loadModels() {
    const request = ++catalogRead;
    catalogLoading = true;
    renderCatalog();
    try {
      const result = await window.nook.commands.models();
      if (request !== catalogRead) return;
      if (!Array.isArray(result) || result.some((provider) => !provider || !Array.isArray(provider.models))) {
        throw new Error('Unexpected provider list. Try again.');
      }
      providers = result;
      catalogReady = true;
      catalogError = '';
    } catch (error) {
      if (request !== catalogRead) return;
      catalogError = `Couldn't load providers. ${messageOf(error)}`;
    } finally {
      if (request === catalogRead) { catalogLoading = false; renderCatalog(); }
    }
  }
  function option(value, label, disabled = false) {
    const element = node('option', '', label);
    element.value = value;
    element.disabled = disabled;
    return element;
  }
  function renderCatalog() {
    if (!draft) return;
    if (!draft.provider && catalogReady) {
      const first = providers.find((provider) => provider.available && provider.models.length) || providers[0];
      draft.provider = first?.id || '';
      draft.model = first?.models[0]?.id || '';
    }
    const providerSelect = $('command-provider'), modelSelect = $('command-model');
    providerSelect.replaceChildren(...providers.map((provider) => option(provider.id, `${provider.name}${provider.available ? '' : ` · ${provider.note || 'Unavailable'}`}`, !provider.available)));
    const provider = providers.find((item) => item.id === draft.provider);
    if (!provider) providerSelect.append(option(draft.provider, draft.provider ? `${draft.provider} · Unavailable` : catalogLoading ? 'Loading providers…' : 'No providers available', true));
    providerSelect.value = draft.provider;
    providerSelect.disabled = !catalogReady;
    const note = provider?.note || (provider && !provider.available ? 'Set up this provider in Nook Settings.' : '');
    $('provider-note').textContent = note;
    $('provider-note').title = note;
    $('provider-note').hidden = !note;
    providerSelect.title = providerSelect.selectedOptions[0]?.textContent || 'Provider';
    modelSelect.replaceChildren(...(provider?.models || []).map((model) => option(model.id, model.name)));
    if (!provider?.models.some((model) => model.id === draft.model)) {
      modelSelect.append(option(draft.model, draft.model ? `${draft.model} · Saved model` : catalogLoading ? 'Loading models…' : 'No models available', true));
    }
    modelSelect.value = draft.model;
    modelSelect.disabled = !provider?.available || !provider.models.length;
    modelSelect.title = modelSelect.selectedOptions[0]?.textContent || 'Model';
    const noProviders = catalogReady && !providers.some((item) => item.available && item.models.length);
    $('models-error').hidden = !catalogError && !noProviders;
    $('models-error-text').textContent = catalogError || 'No models are ready. Set up a provider in Nook Settings, then retry.';
    renderEditorState();
  }
  function canSaveProvider() {
    if (!draft) return false;
    if (draft.id && draft.provider === draft.originalProvider && draft.model === draft.originalModel) return true;
    const provider = providers.find((item) => item.id === draft.provider);
    return !!provider?.available && provider.models.some((model) => model.id === draft.model);
  }
  function renderEditorState() {
    if (!draft) return;
    const missing = !!draft.id && loaded && !findCommand(draft.id);
    $('editor-fields').disabled = !!busy;
    for (const id of ['editor-back', 'cancel-editor', 'duplicate-command', 'keep-command']) $(id).disabled = !!busy;
    $('save-command').disabled = !!busy || missing || !canSaveProvider();
    $('save-command').textContent = busy === 'save' ? 'Saving…' : 'Save';
    $('delete-command').hidden = !draft.id || confirmingDelete;
    $('delete-command').disabled = !!busy || missing;
    $('delete-confirm').hidden = !confirmingDelete;
    $('confirm-delete').disabled = !!busy || missing;
    $('confirm-delete').textContent = busy === 'delete' ? 'Deleting…' : 'Delete';
    $('record-hotkey').disabled = !!busy || !draft.id || missing;
    $('record-hotkey').textContent = busy === 'record' ? 'Press keys…' : draft.hotkey?.display || 'Record hotkey';
    $('record-hotkey').title = !draft.id ? 'Save to add a hotkey.' : 'Record a new hotkey. Esc cancels.';
    $('record-hotkey').setAttribute('aria-label', `Record hotkey${draft.hotkey ? `, current ${draft.hotkey.display}` : ''}`);
    $('clear-hotkey').hidden = !draft.hotkey;
    $('clear-hotkey').disabled = !!busy || missing;
    $('hotkey-hint').textContent = busy === 'record' ? 'Listening for keys… Press Esc to cancel.' : !draft.id ? 'Save to add a hotkey.' : 'Hotkey changes save immediately.';
  }
  function openEditor(command = null, duplicate = false) {
    if (busy || panelOpen) return;
    returnCommandId = command?.id || returnCommandId;
    draft = {
      id: duplicate ? null : command?.id || null,
      name: duplicate ? `${command?.name || 'Untitled command'} copy` : command?.name || '',
      icon: command?.icon || '✨', prompt: command?.prompt || '',
      provider: command?.provider || '', model: command?.model || '',
      effort: command?.effort || 'medium', output: command?.output || 'replace',
      enabled: command?.enabled !== false, hotkey: duplicate ? null : cloneHotkey(command?.hotkey),
      originalProvider: command?.provider, originalModel: command?.model,
    };
    confirmingDelete = false;
    editorError();
    closeEmojiPicker();
    for (const key of ['name', 'prompt', 'effort', 'output']) {
      $(`command-${key}`).value = draft[key];
      $(`command-${key}`).removeAttribute('aria-invalid');
    }
    $('command-enabled').checked = draft.enabled;
    $('command-icon').textContent = draft.icon;
    $('editor-title').textContent = draft.id ? 'Edit command' : duplicate ? 'Duplicate command' : 'New command';
    $('command-output').title = $('command-output').selectedOptions[0]?.textContent || '';
    renderCatalog();
    applyViews();
    document.querySelector('.prompt-pane').scrollTop = 0;
    $('command-name').focus({ preventScroll: true });
    if (!catalogReady && !catalogLoading) void loadModels();
  }
  function closeEditor() {
    if (busy) return;
    draft = null;
    confirmingDelete = false;
    closeEmojiPicker();
    applyViews();
    focusView();
  }
  async function saveCommand() {
    if (!draft || busy) return;
    if (!draft.name.trim()) { editorError('Give this command a name.', $('command-name')); return; }
    if (!draft.prompt.trim()) { editorError('Add a prompt for this command.', $('command-prompt')); return; }
    if (draft.id && !findCommand(draft.id)) { editorError('This command was removed. Duplicate it to keep your edits.'); return; }
    if (!canSaveProvider()) { editorError('Choose an available provider and model.'); return; }
    const editing = draft, revision = listRevision;
    const payload = {
      name: draft.name.trim(), icon: draft.icon, prompt: draft.prompt,
      provider: draft.provider, model: draft.model, effort: draft.effort,
      output: draft.output, enabled: draft.enabled, hotkey: cloneHotkey(draft.hotkey),
    };
    if (draft.id) payload.id = draft.id;
    busy = 'save';
    editorError();
    closeEmojiPicker();
    renderEditorState();
    try {
      const list = await window.nook.commands.save(payload);
      await acceptMutation(list, revision);
      busy = '';
      if (draft === editing) closeEditor();
      $('announcement').textContent = 'Command saved.';
    } catch (error) {
      if (draft === editing) editorError(`Couldn't save the command. ${messageOf(error)}`);
    } finally { busy = ''; renderEditorState(); }
  }
  async function deleteCommand() {
    if (!draft?.id || busy || !confirmingDelete) return;
    const editing = draft, revision = listRevision;
    busy = 'delete';
    editorError();
    renderEditorState();
    try {
      const list = await window.nook.commands.remove(editing.id);
      await acceptMutation(list, revision);
      busy = '';
      if (draft === editing) closeEditor();
      $('announcement').textContent = 'Command deleted.';
    } catch (error) {
      if (draft === editing) editorError(`Couldn't delete the command. ${messageOf(error)}`);
    } finally { busy = ''; renderEditorState(); }
  }
  async function recordHotkey() {
    if (!draft?.id || busy || !findCommand(draft.id)) return;
    const editing = draft, revision = listRevision;
    busy = 'record';
    editorError();
    closeEmojiPicker();
    renderEditorState();
    try {
      const hotkey = await window.nook.commands.recordHotkey(editing.id);
      if (hotkey !== null && (!hotkey || typeof hotkey.display !== 'string')) throw new Error('No hotkey was returned. Try again.');
      if (draft !== editing) return;
      if (hotkey) editing.hotkey = cloneHotkey(hotkey);
      if (hotkey && revision === listRevision) {
        acceptCommands(commands.map((command) => command.id === editing.id ? { ...command, hotkey } : command));
      }
      if (hotkey) await refreshCommands();
      $('announcement').textContent = hotkey ? `Hotkey set to ${hotkey.display}.` : 'Hotkey recording cancelled.';
    } catch (error) {
      if (draft === editing) editorError(`Couldn't record the hotkey. ${messageOf(error)}`);
    } finally {
      busy = '';
      renderEditorState();
      if (draft === editing && !panelOpen) $('record-hotkey').focus({ preventScroll: true });
    }
  }
  async function clearHotkey() {
    if (!draft?.id || busy || !draft.hotkey) return;
    const editing = draft, revision = listRevision;
    busy = 'clear';
    editorError();
    renderEditorState();
    try {
      const list = await window.nook.commands.clearHotkey(editing.id);
      checkList(list);
      if (draft === editing) editing.hotkey = cloneHotkey(list.find((command) => command.id === editing.id)?.hotkey);
      await acceptMutation(list, revision);
      $('announcement').textContent = 'Hotkey cleared.';
    } catch (error) {
      if (draft === editing) editorError(`Couldn't clear the hotkey. ${messageOf(error)}`);
    } finally { busy = ''; renderEditorState(); }
  }

  function closeEmojiPicker(focus = false) {
    $('emoji-picker').hidden = true;
    $('command-icon').setAttribute('aria-expanded', 'false');
    if (focus) $('command-icon').focus();
  }
  function toggleEmojiPicker() {
    if (!draft || busy) return;
    if (!$('emoji-picker').hidden) { closeEmojiPicker(true); return; }
    $('emoji-picker').replaceChildren(...emojis.map(([emoji, label]) => {
      const item = button(emoji, 'nk-btn', () => {
        draft.icon = emoji;
        $('command-icon').textContent = emoji;
        closeEmojiPicker(true);
      });
      item.setAttribute('aria-label', label);
      item.setAttribute('aria-pressed', String(draft.icon === emoji));
      item.title = label;
      return item;
    }));
    $('emoji-picker').hidden = false;
    $('command-icon').setAttribute('aria-expanded', 'true');
    ($('emoji-picker').querySelector('[aria-pressed="true"]') || $('emoji-picker').firstElementChild).focus();
  }

  async function runCommand(id) {
    const command = findCommand(id);
    if (!command || command.enabled === false || isRunning(id) || busy === 'record') return;
    const attempt = { runId: null };
    pendingRuns.set(id, attempt);
    const started = Date.now();
    renderDeck();
    renderResultControls();
    $('result-action-error').hidden = true;
    try {
      await window.nook.commands.run(id);
    } catch (error) {
      const partial = [panelRun, latestRun].find((run) => run && run.runId === attempt.runId);
      // Reuse this attempt's native ID so a rejected stream stops its running
      // indicator without retiring a newer run started by a global hotkey.
      acceptRun({ runId: attempt.runId || `${Date.now()}-local-${++localRun}`, commandId: id, name: command.name, icon: command.icon, status: 'error', error: messageOf(error), text: partial?.text || '', output: command.output, selection: partial?.selection || '' });
    } finally {
      setTimeout(() => { pendingRuns.delete(id); renderDeck(); renderResultControls(); }, Math.max(0, 600 - (Date.now() - started)));
    }
  }
  // Accept epoch seconds/milliseconds (optionally followed by an ID) or ISO dates.
  // Do not guess freshness from digits inside a UUID.
  function runTimestamp(id) {
    const value = String(id ?? '');
    const epoch = value.match(/^(\d{13}|\d{10})(?=$|[-_:])/);
    if (epoch) return Number(epoch[1]) * (epoch[1].length === 10 ? 1000 : 1);
    if (/^\d{10}\.\d+$/.test(value)) return Number(value) * 1000;
    const iso = value.match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})/);
    return iso ? Date.parse(iso[0]) : NaN;
  }
  async function restoreLastRun() {
    const request = ++lastRunRead, revision = runRevision, dismissed = dismissRevision;
    try {
      const run = await window.nook.commands.lastRun();
      if (request !== lastRunRead || revision !== runRevision || dismissed !== dismissRevision) return;
      clearDeckError('lastRun');
      if (run) acceptRun(run, true);
    } catch (error) {
      if (request === lastRunRead && revision === runRevision && dismissed === dismissRevision) {
        deckError('lastRun', `Couldn't restore the last result. ${messageOf(error)}`, restoreLastRun);
      }
    }
  }
  function acceptRun(value, replay = false) {
    if (!value?.runId || !['running', 'done', 'error'].includes(value.status)) throw new Error('Unexpected command result. Try again.');
    const run = { ...value, runId: String(value.runId), text: String(value.text || '') };
    const older = latestRun && latestRun.runId !== run.runId && runTimestamp(run.runId) < runTimestamp(latestRun.runId);
    if (replay && older) return;
    if (runStatuses.has(run.runId) && runStatuses.get(run.runId) !== 'running' && run.status === 'running') return;
    runStatuses.set(run.runId, run.status);
    if (runStatuses.size > 80) runStatuses.delete(runStatuses.keys().next().value);
    const previousActivity = activeRuns.get(run.commandId);
    if (run.status === 'running') {
      const attempt = pendingRuns.get(run.commandId);
      if (!replay && attempt && !attempt.runId) attempt.runId = run.runId;
      if (!previousActivity || !(runTimestamp(run.runId) < runTimestamp(previousActivity))) activeRuns.set(run.commandId, run.runId);
    } else if (previousActivity === run.runId) activeRuns.delete(run.commandId);
    if (!older) latestRun = run;
    runRevision += 1;
    if (previousActivity !== activeRuns.get(run.commandId)) renderDeck();
    const age = Date.now() - runTimestamp(run.runId);
    const eligible = replay ? run.status === 'running' || (run.output === 'notch' && age >= 0 && age < 120000) : (!older && run.output === 'notch') || run.status === 'error';
    const dismissed = dismissedRuns.has(run.runId) && !(run.status === 'error' && dismissedRuns.get(run.runId) !== 'error');
    const samePanel = panelRun?.runId === run.runId;
    if (eligible && !dismissed) {
      const wasOpen = panelOpen;
      panelRun = run;
      panelOpen = true;
      if (!samePanel) {
        copiedRun = null;
        $('result-action-error').hidden = true;
        $('result-text').textContent = '';
      }
      applyViews();
      renderResult(!samePanel);
      if (!wasOpen) $('close-result').focus({ preventScroll: true });
    } else if (samePanel) {
      panelRun = run;
      if (panelOpen) renderResult(false);
    }
    renderResultControls();
  }
  function renderResult(newRun) {
    if (!panelRun) return;
    const run = panelRun, body = $('result-body'), text = $('result-text');
    const selection = window.getSelection();
    const selecting = selection && !selection.isCollapsed && body.contains(selection.anchorNode);
    const follow = newRun || (!selecting && body.scrollHeight - body.scrollTop - body.clientHeight < 32);
    $('result-name').textContent = run.name || 'Command result';
    $('result-name').title = run.name || 'Command result';
    $('result-icon').textContent = run.icon || '✨';
    $('result-spinner').hidden = run.status !== 'running';
    $('result-status').className = `nk-pill${run.status === 'running' ? ' nk-accent' : run.status === 'error' ? ' nk-bad' : ''}`;
    const status = run.status === 'running' ? 'Running…' : run.status === 'error' ? 'Failed' : 'Done';
    if ($('result-status-text').textContent !== status) $('result-status-text').textContent = status;
    $('run-error').hidden = run.status !== 'error';
    $('run-error').textContent = run.status === 'error' ? String(run.error || 'Something went wrong. Try again.') : '';
    const previous = text.textContent;
    // Appending preserves text selection while the native response streams.
    if (previous !== run.text) {
      if (text.firstChild && run.text.startsWith(previous)) text.firstChild.appendData(run.text.slice(previous.length));
      else text.textContent = run.text;
    }
    text.hidden = !run.text;
    $('result-empty').hidden = !!run.text || run.status === 'error';
    $('result-empty-title').textContent = run.status === 'running' ? 'Working on it' : 'No text returned';
    $('result-empty-hint').textContent = run.status === 'running' ? 'The response will appear here.' : 'Try again or adjust the command’s prompt.';
    renderResultControls();
    if (follow) body.scrollTop = body.scrollHeight;
  }
  function renderResultControls() {
    if (!panelRun) return;
    const command = findCommand(panelRun.commandId);
    $('copy-result').disabled = !panelRun.text || copying;
    $('copy-label').textContent = copying ? 'Copying…' : copiedRun === panelRun.runId ? 'Copied' : 'Copy';
    $('retry-result').disabled = !command || command.enabled === false || panelRun.status === 'running' || isRunning(panelRun.commandId) || busy === 'record';
    $('retry-result').title = !command ? 'This command is no longer available.' : command.enabled === false ? 'Enable the command to retry.' : 'Run again using the current selection.';
  }
  function closeResult() {
    if (panelRun) dismissedRuns.set(panelRun.runId, panelRun.status);
    if (dismissedRuns.size > 40) dismissedRuns.delete(dismissedRuns.keys().next().value);
    dismissRevision += 1;
    panelOpen = false;
    applyViews();
    focusView();
  }
  async function copyResult() {
    if (!panelRun?.text || copying) return;
    const run = panelRun;
    copying = true;
    $('result-action-error').hidden = true;
    renderResultControls();
    try {
      await window.nook.clipboard.write(run.text);
      if (panelRun?.runId === run.runId) {
        copiedRun = run.runId;
        clearTimeout(copyTimer);
        copyTimer = setTimeout(() => { copiedRun = null; renderResultControls(); }, 1800);
      }
    } catch (error) {
      if (panelRun?.runId === run.runId) {
        $('result-action-error').textContent = `Couldn't copy the response. ${messageOf(error)}`;
        $('result-action-error').hidden = false;
        $('result-action-error').scrollIntoView({ block: 'nearest' });
      }
    } finally { copying = false; renderResultControls(); }
  }

  function trapTab(event, container) {
    const elements = [...container.querySelectorAll('button:not(:disabled), [tabindex="0"]')].filter((element) => element.getClientRects().length);
    const first = elements[0], last = elements[elements.length - 1];
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
  }
  $('search').addEventListener('input', renderDeck);
  $('new-command').onclick = () => openEditor();
  $('deck-dismiss').onclick = () => clearDeckError();
  $('deck-retry').onclick = () => { if (notice?.retry) void notice.retry(); };
  $('editor-back').onclick = closeEditor;
  $('cancel-editor').onclick = closeEditor;
  $('editor').onsubmit = (event) => { event.preventDefault(); void saveCommand(); };
  $('models-retry').onclick = loadModels;
  $('delete-command').onclick = () => { confirmingDelete = true; renderEditorState(); $('keep-command').focus(); };
  $('keep-command').onclick = () => { confirmingDelete = false; renderEditorState(); $('delete-command').focus(); };
  $('confirm-delete').onclick = deleteCommand;
  $('duplicate-command').onclick = () => { if (draft) openEditor(draft, true); };
  $('command-icon').onclick = toggleEmojiPicker;
  $('record-hotkey').onclick = recordHotkey;
  $('clear-hotkey').onclick = clearHotkey;
  for (const key of ['name', 'prompt', 'effort', 'output']) {
    $(`command-${key}`).addEventListener('input', (event) => {
      if (!draft) return;
      draft[key] = event.target.value;
      event.target.removeAttribute('aria-invalid');
      if (key === 'output') event.target.title = event.target.selectedOptions[0]?.textContent || '';
    });
  }
  $('command-enabled').onchange = (event) => { if (draft) draft.enabled = event.target.checked; };
  $('command-provider').onchange = (event) => {
    if (!draft) return;
    draft.provider = event.target.value;
    draft.model = providers.find((provider) => provider.id === draft.provider)?.models[0]?.id || '';
    renderCatalog();
  };
  $('command-model').onchange = (event) => { if (draft) { draft.model = event.target.value; event.target.title = event.target.selectedOptions[0]?.textContent || ''; renderEditorState(); } };
  $('insert-tokens').onpointerdown = (event) => { if (event.target.closest('[data-token]')) event.preventDefault(); };
  $('insert-tokens').onclick = (event) => {
    const token = event.target.closest('[data-token]')?.dataset.token;
    if (!draft || busy || !token) return;
    const prompt = $('command-prompt');
    prompt.setRangeText(token, prompt.selectionStart, prompt.selectionEnd, 'end');
    draft.prompt = prompt.value;
    prompt.removeAttribute('aria-invalid');
    prompt.focus();
  };
  $('copy-result').onclick = copyResult;
  $('retry-result').onclick = () => { if (panelRun) void runCommand(panelRun.commandId); };
  $('close-result').onclick = closeResult;
  document.addEventListener('pointerdown', (event) => {
    if (!event.target.closest('#emoji-picker, #command-icon')) closeEmojiPicker();
  });
  document.addEventListener('keydown', (event) => {
    if (event.isComposing || busy === 'record') return; // Native owns keys (including Esc) while recording.
    if (event.metaKey && event.key.toLowerCase() === 'n') {
      event.preventDefault();
      if (!busy) { if (panelOpen) closeResult(); openEditor(); }
      return;
    }
    if (panelOpen) {
      if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); closeResult(); }
      else if (event.key === 'Tab') trapTab(event, $('result'));
      return;
    }
    if (!$('emoji-picker').hidden) {
      if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); closeEmojiPicker(true); }
      else if (event.key === 'Tab') trapTab(event, $('emoji-picker'));
      else if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) {
        event.preventDefault();
        const buttons = [...$('emoji-picker').children];
        const offset = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -8, ArrowDown: 8 }[event.key];
        buttons[(buttons.indexOf(document.activeElement) + offset + buttons.length) % buttons.length].focus();
      }
      return;
    }
    if (event.key === 'Escape' && draft) { event.preventDefault(); event.stopPropagation(); closeEditor(); }
    else if (event.key === 'Enter' && event.metaKey && draft) { event.preventDefault(); void saveCommand(); }
    else if (event.key === 'Enter' && event.target.matches('.command-run')) {
      event.preventDefault();
      void runCommand(event.target.closest('.command-card').dataset.commandId);
    }
  });

  async function subscribe(event, handler) {
    if (subscriptions.has(event)) return;
    try {
      await window.nook.on(event, (data) => {
        try { handler(data); }
        catch (error) { deckError('events', `Couldn't update commands. ${messageOf(error)}`, refreshCommands); }
      });
      subscriptions.add(event);
    } catch (error) {
      deckError('events', `Couldn't listen for command updates. ${messageOf(error)}`, subscribeAll);
    }
  }
  async function subscribeAll() {
    await Promise.all([
      subscribe('commands', acceptCommands), subscribe('commandRun', (run) => acceptRun(run)),
      subscribe('open', () => { void restoreLastRun(); }),
      subscribe('show', () => {
        if (panelOpen || draft) focusView();
        else $('search').focus({ preventScroll: true });
        void refreshCommands();
        void loadModels();
        void restoreLastRun();
      }),
    ]);
    if (subscriptions.size === 4) clearDeckError('events');
  }
  async function start() {
    await subscribeAll();
    await Promise.all([refreshCommands(), loadModels(), restoreLastRun()]);
  }
  void start();
})();
