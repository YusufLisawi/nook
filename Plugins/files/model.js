/* Pure presentation helpers, also exercised by the Node mock-bridge tests. */
(function (root) {
  'use strict';
  function segments(name, query) {
    if (!query) return [{ text: name, match: false }];
    const fold = s => s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
    const needle = fold(query.trim());
    if (!needle) return [{ text: name, match: false }];
    let folded = '', offset = 0;
    const starts = [], ends = [];
    for (const character of name) {
      const normalized = fold(character);
      for (let i = 0; i < normalized.length; i++) { starts.push(offset); ends.push(offset + character.length); }
      folded += normalized; offset += character.length;
    }
    const result = []; let cursor = 0, from = 0, match;
    while ((match = folded.indexOf(needle, from)) >= 0) {
      const start = starts[match], end = ends[match + needle.length - 1];
      if (start > cursor) result.push({ text: name.slice(cursor, start), match: false });
      result.push({ text: name.slice(start, end), match: true }); cursor = end; from = match + needle.length;
    }
    if (cursor < name.length) result.push({ text: name.slice(cursor), match: false });
    return result.length ? result : [{ text: name, match: false }];
  }
  function size(bytes) {
    if (!Number.isFinite(bytes) || bytes < 0) return '—';
    if (bytes < 1024) return `${bytes} B`;
    const unit = Math.min(4, Math.floor(Math.log(bytes) / Math.log(1024)));
    return `${(bytes / 1024 ** unit).toFixed(unit === 1 ? 0 : 1)} ${['B', 'KB', 'MB', 'GB', 'TB'][unit]}`;
  }
  function parent(path) { return path.slice(0, path.lastIndexOf('/')) || '/'; }
  function accepts(state, event) {
    return event && event.clientID === state.clientID && String(event.requestID) === String(state.requestID);
  }
  const model = { segments, size, parent, accepts };
  root.FileSearchModel = model;
  if (typeof module !== 'undefined') module.exports = model;
})(typeof window === 'undefined' ? globalThis : window);
