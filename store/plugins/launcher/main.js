(() => {
  const $ = id => document.getElementById(id);
  async function run(action) {
    $('error').hidden = true;
    try { await action(); }
    catch (error) { $('error').textContent = error.message || String(error); $('error').hidden = false; }
    finally { $('loading').hidden = true; $('empty').hidden = false; }
  }
  const refresh = () => run(async () => {
    const state = await nook.native.call('launcher.status');
    $('status').textContent = `${state.applications} applications · ${state.recent} recent items`;
  });
  $('open').onclick = () => run(() => nook.host.call('launcher.open'));
  $('retry').onclick = refresh;
  $('clear').onclick = () => run(async () => { await nook.native.call('launcher.clearHistory'); await refresh(); });
  nook.native.on('ready', refresh); nook.on('show', refresh);
  nook.native.on('error', error => { $('error').textContent = String(error); $('error').hidden = false; });
  nook.on('settings', refresh);
  refresh();
})();
