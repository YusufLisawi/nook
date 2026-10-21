(() => {
  const $ = id => document.getElementById(id);
  const client = new AgentsClient(window.nook, schedule);
  let settings = { recentChats: 5, expandTools: false };
  let scheduled = false, railSignature = '', transcriptID, draftKey, activitySignature = '';
  let choices = [], choiceIndex = 0, returnFocus = null;
  const rendered = new Map();

  function node(tag, className, text) {
    const value = document.createElement(tag);
    if (className) value.className = className;
    if (text !== undefined) value.textContent = text;
    return value;
  }
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => { scheduled = false; render(); });
  }
  globalThis.agentShowError = error => client.fail(error);
  function errorAt(id, error) { $(id).hidden = !error; $(id).textContent = error?.message || String(error || ''); }
  function openSettings() {
    return (async () => {
      try { await client.leave(); await nook.open('nook://settings/agents'); }
      catch (error) { client.fail(error); }
    })();
  }

  function render() {
    $('loading').hidden = !client.loading;
    errorAt('error', client.error);
    $('agent-name').textContent = client.agent?.name || 'Choose an agent';
    $('context').textContent = client.session?.title || (client.agent ? `${client.agent.model} · ${client.agent.workingDirectory}` : 'Create an agent with + to begin.');
    if (client.session && !client.running) {
      const tokens = client.session.usage?.output_tokens;
      $('context').textContent += ` · ${client.session.status}${tokens != null ? ` · ${tokens.toLocaleString()} tokens out` : ''}`;
    }
    $('new').disabled = !client.agent || client.sending;
    $('send').disabled = !client.agent || client.running || client.sending || !$('message').value.trim();
    $('message').disabled = !client.agent || client.sending;
    $('run-state').hidden = !client.running && !client.sending;
    $('run-label').textContent = client.session?.status === 'stopping' ? 'Stopping tools…' : `${client.agent?.name || 'Agent'} is working…`;
    $('stop').hidden = !client.running;
    $('stop').disabled = client.session?.status === 'stopping';
    $('composer-hint').textContent = client.running ? 'You can leave while this agent works.' : 'Enter to send · ⇧Enter for a new line';
    if (draftKey !== client.draftKey) {
      draftKey = client.draftKey;
      $('message').value = client.drafts.get(draftKey) || '';
      $('send').disabled = !client.agent || client.running || client.sending || !$('message').value.trim();
    }
    renderRail(); renderTranscript();
    const live = [...client.chats.values()].filter(c => ['running', 'stopping'].includes(c.status)).map(c => c.id).sort().join(',');
    if (live !== activitySignature) { activitySignature = live; void client.activity(); }
  }

  function renderRail() {
    const signature = JSON.stringify([client.agentId, client.sessionId, settings.recentChats, client.agents,
      [...client.chats.values()].map(c => [c.id, c.title, c.status])]);
    if (signature === railSignature) return;
    railSignature = signature;
    const rows = [];
    if (!client.agents.length && !client.loading) {
      const empty = node('div', 'nk-empty nk-small');
      empty.append(node('b', '', 'Your own agents'), node('span', '', 'Press + to create one.'));
      rows.push(empty);
    }
    for (const agent of client.agents) {
      const active = client.agentId === agent.id && !client.sessionId;
      const button = node('button', 'nk-item agent-row' + (active ? ' nk-selected' : ''));
      button.type = 'button'; button.setAttribute('aria-current', active ? 'true' : 'false');
      button.append(node('span', 'nk-ellipsis nk-fill', agent.name));
      button.onclick = () => choose(agent.id);
      rows.push(button);
      for (const chat of client.recent(agent.id).slice(0, Math.max(1, settings.recentChats))) {
        const current = chat.id === client.sessionId;
        const row = node('button', 'nk-item session-row' + (current ? ' nk-selected' : ''));
        row.type = 'button'; row.title = chat.title; row.setAttribute('aria-current', current ? 'true' : 'false');
        if (['running', 'stopping'].includes(chat.status)) row.append(node('span', 'running-dot'));
        row.append(node('span', 'nk-ellipsis', chat.title)); row.onclick = () => choose(agent.id, chat.id);
        rows.push(row);
      }
    }
    $('rail').replaceChildren(...rows);
  }

  function renderTranscript() {
    const container = $('transcript');
    const id = client.sessionId || 'new:' + client.agentId;
    const nearBottom = container.scrollHeight - container.scrollTop - container.clientHeight < 70;
    const switched = transcriptID !== id;
    if (switched) { transcriptID = id; rendered.clear(); container.replaceChildren(); }
    const items = client.session?.items || [];
    if (!items.length) {
      if (!container.querySelector('.nk-empty')) {
        const empty = node('div', 'nk-empty');
        empty.append(node('b', '', client.agent ? 'What shall we work on?' : 'Meet your next teammate'),
          node('span', 'nk-small', client.agent ? 'Send a message to start a real Codex session.' : 'Create an agent, give it instructions, and start a chat.'));
        container.replaceChildren(empty);
      }
      return;
    }
    const empty = container.querySelector('.nk-empty'); if (empty) empty.remove();
    for (const item of items) {
      const signature = JSON.stringify(item), previous = rendered.get(item.id);
      if (previous?.signature === signature) continue;
      const element = renderItem(item);
      if (previous) {
        const wasFocused = previous.element.contains(document.activeElement);
        if (previous.element.tagName === 'DETAILS') element.open = previous.element.open;
        previous.element.replaceWith(element);
        if (wasFocused) element.querySelector('summary')?.focus();
      } else { container.append(element); }
      rendered.set(item.id, { signature, element });
    }
    if (nearBottom || switched) container.scrollTop = container.scrollHeight;
  }

  function renderItem(item) {
    if (item.type === 'user_message') return node('div', 'bubble user', item.text);
    if (item.type === 'agent_message') {
      const bubble = node('div', 'bubble agent'); bubble.append(agentMarkdown(item.text)); return bubble;
    }
    if (item.type === 'reasoning') return node('div', 'reasoning', item.text);
    if (item.type === 'error') return node('div', 'nk-error', item.message || 'Codex reported an error.');
    const card = node('details', 'tool nk-card'); card.open = Boolean(settings.expandTools);
    const summary = node('summary');
    const status = item.status || 'completed';
    const failed = ['failed', 'error', 'declined', 'interrupted', 'cancelled'].includes(status) || (item.exit_code != null && item.exit_code !== 0);
    const badge = node('span', 'nk-pill ' + (failed ? 'nk-bad' : status === 'in_progress' ? 'nk-accent' : 'nk-good'));
    badge.textContent = item.exit_code != null ? `Exit ${item.exit_code}` : ({ in_progress: 'Running', completed: 'Done' }[status] || status);
    const labels = {
      command_execution: ['⌘', item.command || 'Shell command'],
      file_change: ['↗', `${(item.changes || []).length} file ${(item.changes || []).length === 1 ? 'change' : 'changes'}`],
      web_search: ['⌕', item.query || 'Web search'],
      mcp_tool_call: ['◇', `${item.server || 'MCP'} · ${item.tool || 'Tool'}`],
      collab_tool_call: ['◇', item.tool || 'Agent tool'],
      todo_list: ['☷', 'Plan']
    };
    const [icon, title] = labels[item.type] || ['◇', item.type?.replaceAll('_', ' ') || 'Tool call'];
    summary.append(node('span', 'tool-icon', icon), node('span', 'tool-title', title), badge);
    summary.title = title;
    const body = node('div', 'tool-body');
    const pre = (label, value) => {
      if (value === undefined || value === null || value === '') return;
      if (label) body.append(node('span', 'nk-label', label));
      body.append(node('pre', '', typeof value === 'string' ? value : JSON.stringify(value, null, 2)));
    };
    switch (item.type) {
      case 'command_execution': pre('Command', item.command); pre('Output', item.aggregated_output || (status === 'in_progress' ? 'Waiting for output…' : 'No output.')); break;
      case 'file_change':
        for (const change of item.changes || []) body.append(node('div', 'nk-small', `${change.kind} · ${change.path}`));
        if (item.diff) {
          body.append(node('span', 'nk-label', 'Working-tree preview · may include earlier edits'));
          const diff = node('pre');
          for (const line of item.diff.split('\n')) diff.append(node('span', line.startsWith('+') ? 'diff-add' : line.startsWith('-') ? 'diff-delete' : '', line + '\n'));
          body.append(diff);
        } else { body.append(node('span', 'nk-small nk-muted', 'Codex reports paths only. A diff is shown when available.')); }
        break;
      case 'web_search': pre('Query', item.query); pre('Action', item.action); pre('Results', item.results); break;
      case 'mcp_tool_call': pre('Arguments', item.arguments); pre('Result', item.result); pre('Error', item.error); break;
      case 'todo_list':
        for (const task of item.items || []) body.append(node('div', 'nk-small', `${task.completed ? '✓' : '○'} ${task.text}`));
        break;
      default: pre('', item);
    }
    card.append(summary, body); return card;
  }

  function rememberDraft() { client.drafts.set(client.draftKey, $('message').value); }
  async function choose(agentId, sessionId = null) {
    rememberDraft();
    await client.select(agentId, sessionId);
    $('message').focus();
  }
  async function send(event) {
    event?.preventDefault();
    const text = $('message').value;
    const key = client.draftKey;
    const selection = client.selection;
    rememberDraft();
    if (await client.send(text)) {
      if (client.selection === selection && (client.draftKey === key || $('message').value === text)) {
        $('message').value = client.drafts.get(client.draftKey) || '';
      }
      schedule();
    }
    $('message').focus();
  }

  function showOverlay(id) {
    returnFocus = document.activeElement;
    $(id).hidden = false;
    if (id === 'switcher') { $('search').value = ''; choiceIndex = 0; renderChoices(); $('search').focus(); }
    else { errorAt('create-error', ''); $('create-name').focus(); }
  }
  function closeOverlay() {
    $('switcher').hidden = true; $('create').hidden = true;
    (returnFocus || $('message')).focus();
  }
  function renderChoices() {
    const query = $('search').value.toLowerCase();
    choices = client.agents.flatMap(agent => [
      { agentId: agent.id, title: agent.name, detail: 'New chat' },
      ...client.recent(agent.id).map(s => ({ agentId: agent.id, sessionId: s.id, title: s.title, detail: agent.name }))
    ]).filter(c => `${c.title} ${c.detail}`.toLowerCase().includes(query));
    choiceIndex = Math.max(0, Math.min(choiceIndex, choices.length - 1));
    $('choices').replaceChildren(...choices.map((choice, index) => {
      const button = node('button', 'nk-item' + (index === choiceIndex ? ' nk-selected' : ''));
      button.id = 'choice-' + index; button.type = 'button';
      const text = node('span', 'nk-fill'); text.append(node('div', 'nk-ellipsis', choice.title), node('div', 'nk-small nk-muted', choice.detail));
      button.append(text); button.onclick = () => pickChoice(index); return button;
    }));
    if (!choices.length) $('choices').append(node('div', 'nk-empty', 'No matching agents or chats.'));
    $('search').setAttribute('aria-activedescendant', choices.length ? 'choice-' + choiceIndex : '');
    $('choice-' + choiceIndex)?.scrollIntoView({ block: 'nearest' });
  }
  function pickChoice(index) {
    const choice = choices[index]; if (!choice) return;
    closeOverlay(); void choose(choice.agentId, choice.sessionId);
  }

  $('composer').onsubmit = send;
  $('message').oninput = () => { rememberDraft(); schedule(); };
  $('message').onkeydown = event => {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) { event.preventDefault(); void send(); }
  };
  $('stop').onclick = () => void client.cancel();
  $('new').onclick = () => { if (client.agent) void choose(client.agentId); };
  $('leave').onclick = async () => { await client.leave(); if (client.agent) await choose(client.agentId); };
  $('settings').onclick = openSettings;
  $('switch').onclick = () => showOverlay('switcher');
  $('add').onclick = () => showOverlay('create');
  $('create-cancel').onclick = closeOverlay;
  $('search').oninput = () => { choiceIndex = 0; renderChoices(); };
  $('create-access').onchange = () => {
    $('access-warning').textContent = $('create-access').checked
      ? 'Can run commands, change any files and use the network without approval.'
      : 'Uses the workspace-write sandbox. Commands requiring approval will fail.';
  };
  $('create-form').onsubmit = async event => {
    event.preventDefault(); $('create-save').disabled = true;
    try {
      const agent = await nook.agents.save({ name: $('create-name').value, instructions: $('create-instructions').value,
        workingDirectory: $('create-directory').value || '~', fullAccess: $('create-access').checked });
      if (!client.agents.some(a => a.id === agent.id)) client.agents.push(agent);
      closeOverlay(); await choose(agent.id); $('create-name').value = ''; $('create-instructions').value = '';
    } catch (error) { errorAt('create-error', error); }
    finally { $('create-save').disabled = false; }
  };

  document.addEventListener('keydown', event => {
    const key = event.key.toLowerCase();
    if (event.metaKey && key === 'k') { event.preventDefault(); showOverlay('switcher'); return; }
    if (!$('switcher').hidden || !$('create').hidden) {
      if (key === 'escape') { event.preventDefault(); event.stopPropagation(); closeOverlay(); }
      else if (!$('switcher').hidden && ['arrowdown', 'arrowup'].includes(key)) {
        event.preventDefault(); choiceIndex = (choiceIndex + (key === 'arrowdown' ? 1 : -1) + choices.length) % (choices.length || 1); renderChoices();
      } else if (!$('switcher').hidden && key === 'enter') { event.preventDefault(); pickChoice(choiceIndex); }
      else if (key === 'tab') {
        const overlay = $('switcher').hidden ? $('create') : $('switcher');
        const focusable = [...overlay.querySelectorAll('button:not(:disabled), input, textarea')];
        const index = focusable.indexOf(document.activeElement);
        if ((event.shiftKey && index <= 0) || (!event.shiftKey && index === focusable.length - 1)) {
          event.preventDefault(); focusable[event.shiftKey ? focusable.length - 1 : 0]?.focus();
        }
      }
      return;
    }
    if (event.metaKey && key === 'n') { event.preventDefault(); if (client.agent) void choose(client.agentId); }
    if ((event.metaKey && key === '.') || (key === 'escape' && client.running)) { event.preventDefault(); event.stopPropagation(); void client.cancel(); }
    else if (key === 'escape') {
      event.preventDefault();
      void (async () => { try { await client.leave(); await nook.notch.close(); } catch (error) { client.fail(error); } })();
    }
  });
  $('rail').addEventListener('keydown', event => {
    if (!['ArrowUp', 'ArrowDown'].includes(event.key)) return;
    event.preventDefault();
    const buttons = [...$('rail').querySelectorAll('button')], index = buttons.indexOf(document.activeElement);
    buttons[(index + (event.key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length]?.focus();
  });

  nook.on('agentSession', event => client.apply(event.session, event.item));
  nook.on('agentStorageError', error => client.fail(error));
  nook.on('agents', agents => {
    client.agents = agents || [];
    if (!client.agent) { client.agentId = client.agents[0]?.id || null; client.sessionId = null; }
    schedule();
  });
  const shown = async tab => {
    if (tab !== nook.plugin.id) { await client.leave(); return; }
    client.visible = true;
    await client.load();
    if (client.sessionId) {
      try { client.apply(await nook.agents.open(client.sessionId)); } catch (error) { client.fail(error); }
    }
    $('message').focus();
  };
  nook.on('show', tab => void shown(tab));
  nook.on('open', tab => void shown(tab));
  nook.on('close', () => { closeOverlay(); void client.leave(); void client.activity(); });
  nook.on('settings', values => { settings = { ...settings, ...values }; railSignature = ''; schedule(); });
  void (async () => {
    try { settings = { ...settings, ...await nook.settings.get() }; } catch (error) { client.fail(error); }
    await client.load();
  })();
})();
