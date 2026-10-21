(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const ui = {
    error: $('error'), errorMessage: $('error-message'), retry: $('retry'),
    editView: $('edit-view'), playView: $('play-view'), script: $('script'),
    start: $('start'), saveStatus: $('save-status'), summary: $('script-summary'),
    speed: $('speed'), speedValue: $('speed-value'), font: $('font-size'),
    fontValue: $('font-value'), mirror: $('mirror'), stage: $('stage'),
    prompt: $('prompt-text'), motion: $('prompt-motion'), focus: $('focus-line'),
    progress: $('progress'), progressFill: $('progress-fill'), timeLeft: $('time-left'),
    playbackStatus: $('playback-status'), playbackLabel: $('playback-label'),
    toggle: $('play-pause'), toggleIcon: $('play-pause-icon'), toggleLabel: $('play-pause-label'),
    stop: $('stop'), slower: $('slower'), faster: $('faster'), playSpeed: $('play-speed')
  };
  const settings = { speed: 140, fontSize: 28, mirror: false };
  const dirty = new Set();
  const errors = new Map();
  let script = '';
  let loaded = false;
  let loading = false;
  let saving = false;
  let saveAgain = false;
  let saveTimer = 0;
  let saveFailed = false;
  let errorKind = '';
  let mode = 'edit';
  let busy = false;
  let wantsPlayback = false;
  let cleanupNeeded = false;
  let playing = false;
  let finished = false;
  let frame = 0;
  let previousTime = null;
  let progress = 0;
  let wordCount = 0;
  let travel = 0;
  let origin = 0;
  let lastPercent = -1;

  const countWords = (text) => (text.trim().match(/\S+/gu) || []).length;
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

  function duration(seconds) {
    const total = Math.max(0, Math.ceil(seconds));
    return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
  }

  function showError(kind, message) {
    errors.set(kind, message);
    renderError();
  }

  function clearError(kind) {
    errors.delete(kind);
    renderError();
  }

  function renderError() {
    // A save failure must never hide the recovery action for a pinned panel.
    errorKind = ['cleanup', 'load', 'start', 'save'].find((kind) => errors.has(kind)) || '';
    ui.errorMessage.textContent = errors.get(errorKind) || '';
    ui.error.hidden = !errorKind;
  }

  function updateSaveStatus() {
    const unsaved = saveFailed || dirty.size > 0;
    ui.saveStatus.textContent = !loaded ? 'Loading…' : saving ? 'Saving…' : unsaved ? 'Unsaved changes' : 'Saved';
    ui.saveStatus.dataset.state = saveFailed ? 'unsaved' : '';
  }

  function updateControls() {
    ui.start.disabled = !loaded || busy || cleanupNeeded || !script.trim();
    ui.start.querySelector('span').textContent = busy ? 'One moment…' : 'Start';
    ui.script.disabled = !loaded || busy;
    ui.speed.disabled = !loaded || busy;
    ui.font.disabled = !loaded || busy;
    ui.mirror.disabled = !loaded || busy;
    ui.retry.disabled = loading || busy;
    ui.slower.disabled = busy || settings.speed <= 80;
    ui.faster.disabled = busy || settings.speed >= 260;
  }

  function renderSettings() {
    ui.speed.value = String(settings.speed);
    ui.font.value = String(settings.fontSize);
    ui.speedValue.innerHTML = `${settings.speed} <span>wpm</span>`;
    ui.fontValue.innerHTML = `${settings.fontSize} <span>px</span>`;
    ui.playSpeed.innerHTML = `${settings.speed} <span>wpm</span>`;
    ui.speed.setAttribute('aria-valuetext', `${settings.speed} words per minute`);
    ui.font.setAttribute('aria-valuetext', `${settings.fontSize} pixels`);
    ui.speed.style.setProperty('--fill', `${(settings.speed - 80) / 180 * 100}%`);
    ui.font.style.setProperty('--fill', `${(settings.fontSize - 18) / 30 * 100}%`);
    ui.mirror.setAttribute('aria-pressed', String(settings.mirror));
    ui.prompt.style.fontSize = `${settings.fontSize}px`;
    ui.prompt.classList.toggle('mirrored', settings.mirror);
    updateSummary();
    updateControls();
  }

  function updateSummary() {
    const words = countWords(script);
    ui.summary.textContent = words
      ? `${finished ? 'Finished · ' : ''}${words.toLocaleString()} ${words === 1 ? 'word' : 'words'} · ${duration(words / settings.speed * 60)} at this pace`
      : 'Your next great take starts here.';
    if (mode === 'play') renderProgress();
  }

  function scheduleSave(key) {
    dirty.add(key);
    clearTimeout(saveTimer);
    saveTimer = window.setTimeout(savePending, 400);
    updateSaveStatus();
  }

  // Only one writer can run at a time. Edits made during a write stay dirty.
  async function savePending() {
    clearTimeout(saveTimer);
    if (!loaded || !dirty.size) return;
    if (saving) {
      saveAgain = true;
      return;
    }
    saving = true;
    updateSaveStatus();
    do {
      saveAgain = false;
      const keys = [...dirty];
      const snapshot = { script, settings: { ...settings } };
      dirty.clear();
      let failed = false;
      for (const key of keys) {
        try {
          await window.nook.storage.set(key, snapshot[key]);
        } catch {
          dirty.add(key);
          failed = true;
          saveFailed = true;
          showError('save', 'Couldn’t save your changes. They’re still here — try again.');
        }
      }
      if (failed) break;
      saveFailed = false;
      clearError('save');
    } while (saveAgain && dirty.size);
    saving = false;
    updateSaveStatus();
  }

  async function load() {
    if (loading || loaded) return;
    loading = true;
    updateControls();
    try {
      const storedScript = await window.nook.storage.get('script');
      const storedSettings = await window.nook.storage.get('settings');
      if (storedScript != null && typeof storedScript !== 'string') throw new Error('Invalid script');
      if (storedSettings != null && (typeof storedSettings !== 'object' || Array.isArray(storedSettings))) {
        throw new Error('Invalid settings');
      }
      script = storedScript || '';
      if (storedSettings) {
        settings.speed = typeof storedSettings.speed === 'number' && Number.isFinite(storedSettings.speed)
          ? clamp(Math.round(storedSettings.speed / 5) * 5, 80, 260) : 140;
        settings.fontSize = typeof storedSettings.fontSize === 'number' && Number.isFinite(storedSettings.fontSize)
          ? clamp(Math.round(storedSettings.fontSize), 18, 48) : 28;
        settings.mirror = storedSettings.mirror === true;
      }
      ui.script.value = script;
      loaded = true;
      clearError('load');
      renderSettings();
    } catch {
      showError('load', 'Couldn’t load your script. Open this in Nook, or try again.');
      ui.saveStatus.textContent = 'Unavailable';
    }
    loading = false;
    if (loaded) updateSaveStatus();
    updateControls();
  }

  function renderProgress() {
    ui.motion.style.transform = `translate3d(0, ${origin - travel * progress}px, 0)`;
    ui.progressFill.style.transform = `scaleX(${progress})`;
    const percent = Math.floor(progress * 100);
    if (percent !== lastPercent) {
      lastPercent = percent;
      ui.progress.setAttribute('aria-valuenow', String(percent));
    }
    ui.timeLeft.textContent = `${duration((1 - progress) * wordCount / settings.speed * 60)} left`;
  }

  function measurePrompt() {
    if (mode !== 'play') return;
    const lineHeight = settings.fontSize * 1.5;
    // The first line starts at the camera guide. A full text-height of travel
    // gives every word its share of time, including a short, single-line script.
    origin = ui.focus.offsetTop - lineHeight / 2;
    travel = Math.max(lineHeight, ui.prompt.scrollHeight);
    renderProgress();
  }

  function tick(timestamp) {
    if (!playing || mode !== 'play') return;
    if (previousTime !== null) {
      // Don't skip ahead if the webview was hidden or a frame was suspended.
      const seconds = Math.min(100, timestamp - previousTime) / 1000;
      progress = Math.min(1, progress + seconds * settings.speed / (60 * wordCount));
    }
    previousTime = timestamp;
    renderProgress();
    if (progress >= 1) {
      finished = true;
      void stopPlayback();
      return;
    }
    frame = requestAnimationFrame(tick);
  }

  function renderPlaybackState() {
    ui.toggleIcon.setAttribute('href', playing ? '#i-pause' : '#i-play');
    ui.toggleLabel.textContent = playing ? 'Pause' : 'Resume';
    ui.toggle.title = `${playing ? 'Pause' : 'Resume'} (Space)`;
    ui.playbackLabel.textContent = playing ? 'Prompting' : 'Paused';
    ui.playbackStatus.classList.toggle('paused', !playing);
  }

  // Try every cleanup operation even if one bridge call fails.
  async function releaseNotch() {
    let ok = true;
    try {
      await window.nook.activity.clear();
    } catch { ok = false; }
    try {
      await window.nook.notch.pin(false);
    } catch { ok = false; }
    try {
      await window.nook.notch.setHeight(230);
    } catch { ok = false; }
    cleanupNeeded = !ok;
    if (!ok) showError('cleanup', 'The script stopped, but the panel couldn’t reset. Try again.');
    else clearError('cleanup');
    return ok;
  }

  async function startPlayback() {
    if (!loaded || busy || cleanupNeeded || mode === 'play' || !script.trim()) return;
    busy = true;
    wantsPlayback = true;
    finished = false;
    updateControls();
    await savePending();
    if (!wantsPlayback) {
      busy = false;
      updateControls();
      return;
    }
    try {
      await window.nook.notch.pin(true);
      if (wantsPlayback) await window.nook.notch.setHeight(300);
      if (wantsPlayback) await window.nook.activity.set({ text: 'Prompting', symbol: 'text.alignleft', color: '#ff9f0a' });
    } catch {
      const restored = await releaseNotch();
      if (restored) showError('start', 'Couldn’t start prompting. Your script is safe here — try again.');
      wantsPlayback = false;
      busy = false;
      updateControls();
      return;
    }
    if (!wantsPlayback) {
      await releaseNotch();
      busy = false;
      updateControls();
      return;
    }
    clearError('start');
    mode = 'play';
    playing = true;
    progress = 0;
    lastPercent = -1;
    previousTime = null;
    wordCount = countWords(script);
    ui.prompt.textContent = script.trim();
    ui.editView.hidden = true;
    ui.playView.hidden = false;
    busy = false;
    renderSettings();
    renderPlaybackState();
    measurePrompt();
    ui.toggle.focus({ preventScroll: true });
    frame = requestAnimationFrame(tick);
  }

  async function stopPlayback() {
    wantsPlayback = false;
    // Escape during startup is handled as soon as the pending call finishes.
    if (busy) return;
    if (mode !== 'play' && !cleanupNeeded) return;
    busy = true;
    playing = false;
    cancelAnimationFrame(frame);
    previousTime = null;
    mode = 'edit';
    ui.playView.hidden = true;
    ui.editView.hidden = false;
    updateControls();
    await releaseNotch();
    await savePending();
    busy = false;
    updateSummary();
    updateControls();
    if (!cleanupNeeded) ui.start.focus({ preventScroll: true });
  }

  function togglePlayback() {
    if (busy) return;
    if (mode === 'edit') {
      void startPlayback();
      return;
    }
    playing = !playing;
    previousTime = null;
    cancelAnimationFrame(frame);
    renderPlaybackState();
    if (playing) frame = requestAnimationFrame(tick);
  }

  function changeSpeed(value) {
    if (!loaded || busy) return;
    const next = clamp(Math.round(value / 5) * 5, 80, 260);
    if (next === settings.speed) return;
    settings.speed = next;
    renderSettings();
    scheduleSave('settings');
  }

  ui.script.addEventListener('input', () => {
    script = ui.script.value;
    finished = false;
    updateSummary();
    updateControls();
    scheduleSave('script');
  });
  ui.speed.addEventListener('input', () => changeSpeed(Number(ui.speed.value)));
  ui.font.addEventListener('input', () => {
    settings.fontSize = clamp(Number(ui.font.value), 18, 48);
    renderSettings();
    scheduleSave('settings');
  });
  ui.mirror.addEventListener('click', () => {
    settings.mirror = !settings.mirror;
    renderSettings();
    scheduleSave('settings');
  });
  ui.start.addEventListener('click', startPlayback);
  ui.toggle.addEventListener('click', togglePlayback);
  ui.stop.addEventListener('click', stopPlayback);
  ui.slower.addEventListener('click', () => changeSpeed(settings.speed - 10));
  ui.faster.addEventListener('click', () => changeSpeed(settings.speed + 10));
  ui.retry.addEventListener('click', async () => {
    if (errorKind === 'load') await load();
    else if (errorKind === 'save') await savePending();
    else if (errorKind === 'cleanup') await stopPlayback();
    else if (errorKind === 'start') await startPlayback();
  });

  document.addEventListener('keydown', (event) => {
    if (event.defaultPrevented || event.isComposing) return;
    if (event.metaKey && event.key === 'Enter' && !event.ctrlKey && !event.altKey) {
      event.preventDefault();
      if (!event.repeat) togglePlayback();
      return;
    }
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key === 'Escape' && (mode === 'play' || busy)) {
      event.preventDefault();
      void stopPlayback();
      return;
    }
    // Keep spaces and arrow keys available when writing or adjusting a slider.
    if (mode === 'edit' && event.target.closest('textarea, input, button, select, [contenteditable="true"]')) return;
    if (event.code === 'Space' || event.key === ' ') {
      event.preventDefault();
      if (!event.repeat) togglePlayback();
    } else if (mode === 'play' && (event.key === 'ArrowUp' || event.key === 'ArrowDown')) {
      event.preventDefault();
      changeSpeed(settings.speed + (event.key === 'ArrowUp' ? 10 : -10));
    }
  });

  document.addEventListener('visibilitychange', () => {
    if (document.hidden) void savePending();
    previousTime = null;
  });
  window.addEventListener('pagehide', () => {
    void savePending();
    // Nook normally keeps the webview alive; also release it on a true unload.
    if (mode === 'play' || busy) void stopPlayback();
  });
  if (typeof ResizeObserver !== 'undefined') new ResizeObserver(measurePrompt).observe(ui.stage);
  else window.addEventListener('resize', measurePrompt);

  renderSettings();
  void load();
})();
