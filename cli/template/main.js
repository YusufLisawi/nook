// __NAME__ — a Nook plugin. Docs: `nook api` (bridge) and `nook guide` (UI). Logs: `nook logs __ID__ -f`.
const $ = (id) => document.getElementById(id);
let items = [];

async function load() {
  try {
    items = (await nook.storage.get('items')) || [];
  } catch (err) {
    console.error('load failed', err);
  }
  render();
}

function render() {
  $('empty').hidden = items.length > 0;
  $('list').replaceChildren(...items.map((item, i) => {
    const row = document.createElement('div');
    row.className = 'nk-item nk-in';
    const text = document.createElement('span');
    text.className = 'nk-fill nk-ellipsis';
    text.textContent = item.text;
    const actions = document.createElement('span');
    actions.className = 'nk-actions';
    const del = document.createElement('button');
    del.className = 'nk-icon-btn';
    del.title = 'Delete';
    del.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>';
    del.onclick = () => save(items.filter((_, j) => j !== i));
    actions.append(del);
    row.append(text, actions);
    return row;
  }));
}

async function save(next) {
  items = next;
  render();
  await nook.storage.set('items', items);
}

$('add').addEventListener('submit', (e) => {
  e.preventDefault();
  const text = $('text').value.trim();
  if (!text) return;
  $('text').value = '';
  save([...items, { text, at: Date.now() }]);
});

nook.on('show', (tab) => { if (tab === nook.plugin.id) $('text').focus(); });
load();
