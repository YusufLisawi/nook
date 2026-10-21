// Static actions complement the tab's roving rows and native controls.
(() => {
  'use strict';
  const definitions = [
  {
    "id": "inspect-metrics",
    "title": "Inspect system metrics",
    "selector": "#cpu-tile",
    "focus": true
  }
];
  if (!window.nook?.actions) return;
  const run = id => {
    const action = definitions.find(item => item.id === id);
    if (!action) return;
    const target = document.querySelector(action.selector);
    if (!target || target.disabled || target.closest('[hidden]')) return;
    if (action.focus) target.focus();
    else target.click();
  };
  nook.on('action', run);
  nook.on('actionAlternate', run);
  nook.actions.register(definitions.map(({ id, title, subtitle, shortcut }) => ({ id, title, ...(subtitle ? { subtitle } : {}), ...(shortcut ? { shortcut } : {}) }))).catch(error => {
    const message = document.createElement('div');
    message.className = 'nk-error';
    message.setAttribute('role', 'status');
    message.textContent = `Actions unavailable: ${error.message || error}`;
    document.querySelector('main')?.append(message);
  });
})();
