/* Pure display/navigation helpers; also exercised by the isolated mock harness. */
(() => {
  'use strict';
  const captions = (value, now = new Date()) => {
    const date = new Date(value);
    if (!Number.isFinite(date.getTime())) return '';
    const yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
    const day = date.toDateString() === now.toDateString() ? 'Today' : date.toDateString() === yesterday.toDateString() ? 'Yesterday' : date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    return `${day} at ${date.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', hour12: false })}`;
  };
  const move = (index, key, count, columns = 1) => {
    if (!count) return -1;
    if (index < 0) return key === 'ArrowUp' ? count - 1 : 0;
    const delta = { ArrowDown: columns, ArrowUp: -columns, ArrowRight: 1, ArrowLeft: -1 }[key] || 0;
    return Math.max(0, Math.min(count - 1, index + delta));
  };
  const canOpen = (item) => !!item && (item.hasFile || item.kind === 'link');
  const normalize = (items) => {
    if (!Array.isArray(items)) throw new Error('Nook returned an invalid history. Try Refresh.');
    return items.filter((item) => item && typeof item.id === 'string' && typeof item.kind === 'string')
      .sort((a, b) => Number(!!b.pinned) - Number(!!a.pinned) || b.date - a.date);
  };
  globalThis.ClipsUI = { captions, move, canOpen, normalize };
})();
