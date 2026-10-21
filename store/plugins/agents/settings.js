(() => {
'use strict';
const $ = id => document.getElementById(id), agent = nook.plugin.id === 'agents', ns = agent ? 'agents' : 'commands';
let providers = [], modelChoices = [];
let rows = [], selected = null, pendingDelete = false, saveTimer;
const error = e => { $('error').hidden = !e; $('error').textContent = e ? String(e.message || e) : ''; };
const call = (fn, ...args) => nook.native.call(ns + '.' + fn, {args});
const fields = agent ? [ ['name','Name'], ['instructions','Instructions','text'], ['workingDirectory','Working folder'], ['model','Model'], ['effort','Reasoning',['low','medium','high','xhigh','max','ultra']], ['fullAccess','Full access','check'] ] : [ ['name','Name'],['prompt','Prompt','text'],['provider','Provider',['codex','groq','openai']],['model','Model'],['effort','Reasoning',['none','low','medium','high']],['output','Output',['replace','paste','copy','notch']],['copyToo','Also copy the answer','check'],['enabled','Enabled','check'] ];
function list() {
 $('list').replaceChildren(...rows.map(row => { const b = document.createElement('button'); b.type = 'button'; b.className = 'nk-item' + (row.id === selected ? ' nk-selected' : ''); b.dataset.nkItem = row.id; b.textContent = row.name; b.onclick = () => choose(row.id); return b; }));
 if (!rows.length) $('list').textContent = agent ? 'No agents. Add one to begin.' : 'No commands. Add one to begin.';
}
function choose(id) {
 if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; save(); } selected = id; pendingDelete = false; $('remove').textContent = 'Delete'; list(); $('fields').replaceChildren();
 const row = rows.find(r => r.id === id); $('fields').hidden = !row; $('empty').hidden = !!row; $('save').disabled = !row; $('remove').disabled = !row;
 if (!row) return;
 for (const [key,title,type] of fields) {
  const label = document.createElement('label'); label.textContent = title;
  const input = document.createElement(Array.isArray(type) ? 'select' : type === 'text' ? 'textarea' : 'input');
  input.className = type === 'text' ? 'nk-textarea' : 'nk-input'; input.name = key; input.id = 'field-' + key;
  if (Array.isArray(type)) for (const v of type) { const o = document.createElement('option'); o.value = v; o.textContent = v; input.append(o); }
  if (type === 'check') { input.type = 'checkbox'; input.checked = !!row[key]; label.className = 'check'; } else { input.value = row[key] || ''; }
  input.oninput = () => { row[key] = type === 'check' ? input.checked : input.value; $('status').textContent = 'Unsaved changes'; clearTimeout(saveTimer); saveTimer = setTimeout(save, 600); };
  if (key === 'model') { input.setAttribute('list','model-choices'); const choices = document.createElement('datalist'); choices.id = 'model-choices'; const models = agent ? modelChoices : (providers.find(p => p.id === row.provider)?.models || []); for (const model of models) { const option = document.createElement('option'); option.value = model.id; option.textContent = model.name || model.id; choices.append(option); } label.append(choices); }
  if (key === 'provider') input.addEventListener('change', () => { const models = providers.find(p => p.id === row.provider)?.models || []; if (models.length) { row.model = models[0].id; choose(row.id); save(); } });
  label.append(input); $('fields').append(label);
 }
 if (agent) {
  const hint = document.createElement('p'); hint.className = 'hint'; hint.textContent = 'Full access allows this agent to run commands, change files anywhere and use the network without approval. Only use instructions and tools you trust.'; $('fields').append(hint);
  const pick = document.createElement('button'); pick.type = 'button'; pick.className = 'nk-btn'; pick.textContent = 'Choose working folder…'; pick.onclick = async () => { try { const path = await nook.host.call('settings.chooseDirectory',{}); if (path) { row.workingDirectory = path; choose(row.id); await save(); } } catch(e) { error(e); } }; $('fields').append(pick);
 } else {
  const hint = document.createElement('p'); hint.className = 'hint'; hint.textContent = 'Placeholders: {selection}, {clipboard}, {app}, {date}, {time}. Prompts are sent to the chosen AI provider.'; $('fields').append(hint);
  const shortcut = document.createElement('button'); shortcut.type = 'button'; shortcut.className = 'nk-btn'; shortcut.textContent = row.hotkey?.display || 'Record global shortcut';
  shortcut.onclick = async () => { try { shortcut.textContent = 'Press shortcut…'; const k = await nook.host.call('hotkeys.record',{}); row.hotkey = k; shortcut.textContent = k?.display || 'Off'; await save(); } catch(e) { error(e); shortcut.textContent = row.hotkey?.display || 'Off'; } }; $('fields').append(shortcut);
 }
}
async function load() { try { if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; await save(); } error(null); const models = await call('models'); if (agent) modelChoices = models || []; else providers = models || []; rows = await call('list'); choose(rows.some(r => r.id === selected) ? selected : rows[0]?.id); } catch(e) { error(e); $('list').textContent = 'Couldn’t load. Choose Reload to retry.'; } }
async function save() { const row = rows.find(r => r.id === selected); if (!row) return; try { error(null); $('status').textContent = 'Saving…'; await call('save', row); $('status').textContent = 'Saved'; list(); } catch(e) { error(e); $('status').textContent = 'Changes not saved'; } }
$('form').onsubmit = e => { e.preventDefault(); clearTimeout(saveTimer); save(); };
$('add').onclick = async () => { const row = {id:crypto.randomUUID(),name:agent ? 'New agent' : 'New command', ...(agent ? {instructions:'',workingDirectory:'~',model:'gpt-6.1-sol',effort:'ultra',fullAccess:true} : {prompt:'{selection}',provider:'codex',model:'gpt-6-luna',effort:'none',output:'replace',copyToo:false,enabled:true,hotkey:null})}; rows.push(row); choose(row.id); await save(); };
$('duplicate').onclick = async () => { const source = rows.find(r => r.id === selected); if (!source) return; const row = {...source,id:crypto.randomUUID(),name:source.name + ' copy'}; if (!agent) row.hotkey = null; rows.push(row); choose(row.id); await save(); };
$('remove').onclick = async () => { if (!selected) return; if (!pendingDelete) { pendingDelete = true; $('remove').textContent = 'Confirm deletion'; return; } try { if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; await save(); } await call('remove',selected); selected = null; await load(); } catch(e) { error(e); } };
$('reload').onclick = load;
document.addEventListener('keydown', e => { if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { e.preventDefault(); clearTimeout(saveTimer); save(); } if (e.key === 'Escape') { pendingDelete = false; $('remove').textContent = 'Delete'; } });
nook.native.on('ready',load); load();
})();
