// Injected after window.nook. Opt in to arrow navigation with .nk-roving + [data-nk-item].
(() => {
  'use strict';
  const controls = 'button,input,select,textarea,a[href],[contenteditable="true"],[tabindex]';
  const visible = el => !el.disabled && el.getAttribute('aria-disabled') !== 'true' &&
    !el.closest('[hidden],[inert]') && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
  const editable = el => el.matches('input,textarea,select,[contenteditable]:not([contenteditable="false"]),[role="slider"]');
  const items = group => [...group.querySelectorAll('[data-nk-item]')].filter(el => el.closest('.nk-roving') === group && visible(el));
  let lastFocus = null, requested = false;

  function remember(el) {
    const group = el.closest('.nk-roving');
    const item = el.closest('[data-nk-item]');
    lastFocus = group && item ? { el, group, key: item.getAttribute('data-nk-item'), index: items(group).indexOf(item), control: [...item.querySelectorAll(controls)].indexOf(el) } : null;
  }
  function refresh() {
    for (const group of document.querySelectorAll('.nk-roving')) {
      const rows = items(group);
      for (const row of group.querySelectorAll('[data-nk-item]')) {
        if (row.closest('.nk-roving') === group && !rows.includes(row)) row.tabIndex = -1;
      }
      const active = rows.find(el => el === document.activeElement || el.contains(document.activeElement)) || rows.find(el => el.tabIndex === 0) || rows[0];
      for (const row of rows) {
        row.tabIndex = row === active ? 0 : -1;
        if (!row.matches('button,a,input,select,textarea') && !row.hasAttribute('role')) row.setAttribute('role', 'button');
      }
    }
    if (lastFocus && !lastFocus.el.isConnected && lastFocus.group.isConnected && document.activeElement === document.body) {
      const rows = items(lastFocus.group);
      const replacement = rows.find(el => lastFocus.key && el.getAttribute('data-nk-item') === lastFocus.key) || rows[Math.min(Math.max(lastFocus.index, 0), rows.length - 1)];
      if (replacement) {
        const control = lastFocus.control >= 0 ? replacement.querySelectorAll(controls)[lastFocus.control] : null;
        (control && visible(control) ? control : replacement).focus({ preventScroll: true });
      }
    }
    if (requested) focus();
  }
  function focus() {
    requested = true;
    if (!document.body) return;
    refreshWithoutRequest();
    const preferred = [...document.querySelectorAll('[data-nk-autofocus]')].find(visible) ||
      [...document.querySelectorAll('input[type="search"],input:not([type]),textarea,[data-nk-item],button,select,[tabindex="0"]')].find(visible);
    if (preferred) {
      requested = false;
      preferred.focus({ preventScroll: true });
    }
  }
  function refreshWithoutRequest() {
    const pending = requested;
    requested = false;
    refresh();
    requested = pending;
  }
  window.nook.keyboard = { focus };
  document.addEventListener('focusin', event => {
    requested = false;
    remember(event.target);
    const row = event.target.closest('[data-nk-item]');
    const group = row?.closest('.nk-roving');
    if (group) for (const item of items(group)) item.tabIndex = item === row ? 0 : -1;
  });
  document.addEventListener('keydown', event => {
    if (event.defaultPrevented || event.isComposing) return;
    const target = event.target;
    // WebKit's macOS setting may skip buttons on Tab; include every usable control.
    if (event.key === 'Tab' && !event.ctrlKey && !event.metaKey && !event.altKey) {
      const nodes = [...document.querySelectorAll(controls)].filter(el => el.tabIndex >= 0 && visible(el));
      const index = nodes.indexOf(target);
      const next = nodes[index + (event.shiftKey ? -1 : 1)];
      if (next) { event.preventDefault(); next.focus(); }
      return;
    }
    const row = target.closest('[data-nk-item]');
    const group = row?.closest('.nk-roving');
    if (!group || !visible(row) || editable(target) || (target !== row && target.closest(controls) !== row)) return;
    if (event.ctrlKey || event.altKey || event.shiftKey) return;
    if (event.key === 'Enter' || (event.key === ' ' && !row.matches('button,input'))) {
      event.preventDefault();
      if (event.metaKey) row.dispatchEvent(new CustomEvent('nk:alt', { bubbles: true, detail: { item: row } }));
      else row.click();
      return;
    }
    if (event.metaKey) return;
    const horizontal = group.dataset.nkOrientation === 'horizontal';
    const keys = horizontal ? ['ArrowLeft', 'ArrowRight'] : ['ArrowUp', 'ArrowDown'];
    if (![...keys, 'Home', 'End'].includes(event.key)) return;
    const rows = items(group);
    const index = rows.indexOf(row);
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? rows.length - 1 : (index + (event.key === keys[1] ? 1 : -1) + rows.length) % rows.length;
    event.preventDefault();
    rows[next]?.focus();
    rows[next]?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  });
  const observer = new MutationObserver(refresh);
  observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['hidden', 'disabled', 'aria-disabled'] });
  window.addEventListener('pagehide', () => observer.disconnect(), { once: true });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', refresh, { once: true });
  else refresh();
})();
