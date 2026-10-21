const get = id => document.getElementById(id);
async function run() {
  get('loading').hidden = false; get('empty').hidden = true;
  get('error').hidden = true; get('run').disabled = true;
  try {
    const reply = await nook.native.call('hello', { name: nook.plugin.name });
    get('result').textContent = reply.message;
    get('result').hidden = !reply.message;
    get('empty').hidden = !!reply.message;
  } catch (error) {
    get('error').textContent = `${error.message || error} — allow access in Settings, build the helper, then retry.`;
    get('error').hidden = false;
  } finally { get('loading').hidden = true; get('run').disabled = false; }
}
get('run').addEventListener('click', run);
get('run').addEventListener('keydown', e => { if (e.key === 'Enter' && e.metaKey) { e.preventDefault(); run(); } });
nook.native.on('ready', run);
nook.on('open', run);
run();
