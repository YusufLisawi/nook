// AI Commands — pills to run saved prompts on the current selection. Editing lives in Settings → AI Commands.
const $ = (id) => document.getElementById(id);
let commands = [];
let runningId = null;
let shownRun = null;

function showError(message) {
  $('error').hidden = !message;
  $('error').textContent = message || '';
}

function render() {
  const visible = commands.filter((c) => c.enabled);
  $('empty').hidden = visible.length > 0;
  $('deck').replaceChildren(...visible.map((c) => {
    const pill = document.createElement('button');
    pill.dataset.nkItem = c.id;
    pill.addEventListener('nk:alt', () => $('edit').click());
    pill.className = 'pill' + (c.id === runningId ? ' running' : '');
    pill.title = c.output === 'notch' ? 'Shows the answer here' : c.output === 'copy' ? 'Copies the answer' : 'Replaces your selection';
    if (c.id === runningId) pill.append(Object.assign(document.createElement('span'), { className: 'dot' }));
    pill.append(document.createTextNode(c.name));
    if (c.hotkey) pill.append(Object.assign(document.createElement('span'), { className: 'key', textContent: c.hotkey.display }));
    pill.onclick = () => run(c.id);
    return pill;
  }));
}

async function run(id) {
  try {
    showError('');
    runningId = id;
    render();
    await nook.commands.run(id);
  } catch (err) {
    runningId = null;
    render();
    showError(err.message || String(err));
  }
}

function showRun(r) {
  shownRun = r;
  $('result').hidden = false;
  $('r-name').textContent = r.name;
  const status = $('r-status');
  status.className = 'nk-pill ' + (r.status === 'error' ? 'nk-bad' : r.status === 'done' ? 'nk-good' : 'nk-accent');
  status.textContent = r.status === 'error' ? 'Failed' : r.status === 'done' ? 'Done' : 'Thinking…';
  $('r-text').textContent = r.status === 'error' ? (r.error || 'Something went wrong') : (r.text || '');
  $('r-copy').disabled = r.status !== 'done';
}

nook.on('commandRun', (r) => {
  runningId = r.status === 'running' ? r.commandId : null;
  render();
  if (r.output === 'notch' || r.status === 'error') showRun(r);
});
nook.on('commands', (list) => { commands = list || []; render(); });

$('r-copy').onclick = async () => {
  try { await nook.clipboard.write(shownRun ? shownRun.text : ''); $('r-copy').textContent = 'Copied'; setTimeout(() => { $('r-copy').textContent = 'Copy'; }, 1200); }
  catch (err) { showError(err.message || String(err)); }
};
$('r-retry').onclick = () => { if (shownRun) run(shownRun.commandId); };
$('r-close').onclick = () => { $('result').hidden = true; shownRun = null; };
$('edit').onclick = () => nook.open('nook://settings/commands').catch(err => showError(err.message || String(err)));
$('setup').onclick = () => nook.open('nook://settings/ai').catch(err => showError(err.message || String(err)));
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !$('result').hidden) { e.stopPropagation(); $('r-close').click(); } });

async function load() {
  try {
    commands = await nook.commands.list();
    render();
    const providers = await nook.commands.models();
    const codex = providers.find((p) => p.id === 'codex');
    $('connect').hidden = !(codex && !codex.available && commands.some((c) => c.provider === 'codex'));
    const last = await nook.commands.lastRun();
    if (last && (last.status === 'running' || (last.output === 'notch' && Date.now() - Number(last.runId) < 120000))) showRun(last);
  } catch (err) {
    showError(err.message || String(err));
  } finally { $('loading').hidden = true; }
}
nook.on('show', (tab) => { if (tab === nook.plugin.id) load(); });
load();

nook.native.on('shortcutError', showError);
