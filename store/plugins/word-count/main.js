(() => {
  const nook = window.nook;
  const $ = (id) => document.getElementById(id);
  let ready = false, loading = false, focusWhenReady = false, settings = { showCharacters: true }, timer, saving = false, dirty = false, failed = '';
  const words = (text) => (text.trim().match(/\S+/gu) || []).length;
  const summary = () => `${words($('draft').value)} words${settings.showCharacters === false ? '' : ` · ${[...$('draft').value].length} characters`}`;
  function render() {
    $('counts').textContent = summary();
    $('empty').hidden = !ready || $('draft').value.length > 0;
    $('copy').disabled = !ready;
  }
  function showError(error, kind) {
    failed = kind;
    $('error').textContent = `Couldn't ${kind}: ${error.message || error}. Try again.`;
    $('error').hidden = false;
    $('retry').hidden = false;
  }
  function clearError() {
    failed = '';
    $('error').hidden = true;
    $('retry').hidden = true;
  }
  async function save() {
    clearTimeout(timer);
    if (!ready || saving || !dirty) return;
    saving = true;
    dirty = false;
    const draft = $('draft').value;
    $('status').textContent = 'Saving…';
    try {
      await nook.storage.set('draft', draft);
      if (failed === 'save draft') clearError();
      $('status').textContent = 'Saved';
    } catch (error) {
      dirty = true;
      $('status').textContent = 'Unsaved';
      showError(error, 'save draft');
    } finally {
      saving = false;
      // Serialize writes; new edits are saved after the in-flight write finishes.
      if (dirty && failed !== 'save draft') void save();
    }
  }
  async function load() {
    if (loading || ready) return;
    loading = true;
    $('loading').hidden = false;
    $('retry').disabled = true;
    try {
      const draft = await nook.storage.get('draft');
      const options = await nook.settings.get();
      settings = options || settings;
      $('draft').value = typeof draft === 'string' ? draft : '';
      ready = true;
      $('draft').disabled = false;
      clearError();
      if (focusWhenReady) { focusWhenReady = false; $('draft').focus(); }
    } catch (error) { showError(error, 'load draft'); }
    finally { loading = false; $('loading').hidden = true; $('retry').disabled = false; render(); }
  }
  async function copy() {
    if (!ready) return;
    try {
      await nook.clipboard.write(summary());
      $('status').textContent = 'Counts copied';
      if (failed === 'copy counts') clearError();
    } catch (error) { showError(error, 'copy counts'); }
  }
  $('draft').addEventListener('input', () => {
    if (!ready) return;
    dirty = true;
    render();
    $('status').textContent = 'Unsaved';
    clearTimeout(timer);
    timer = setTimeout(() => { void save(); }, 350);
  });
  $('draft').addEventListener('blur', () => { void save(); });
  $('copy').addEventListener('click', () => { void copy(); });
  $('retry').addEventListener('click', () => {
    if (failed === 'load draft') void load();
    else if (failed === 'copy counts') void copy();
    else void save();
  });
  document.addEventListener('keydown', (event) => {
    if (event.metaKey && event.key === 'Enter') { event.preventDefault(); void copy(); }
    // Arrow keys and Enter keep native textarea behavior; Escape belongs to Nook.
  });
  nook.on('settings', (options) => { settings = options || {}; render(); });
  nook.on('show', () => { if (ready) $('draft').focus(); else focusWhenReady = true; });
  nook.on('close', () => { focusWhenReady = false; void save(); });
  window.addEventListener('pagehide', () => { void save(); });
  void load();
})();
