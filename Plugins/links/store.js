/* Shared JSON storage helpers. Never write the display cache back to storage. */
const LinksData = (() => {
  'use strict';
  const clone = (value) => JSON.parse(JSON.stringify(value));
  const validLink = (item) => item && typeof item.id === 'string' && !!item.id && typeof item.url === 'string' && !!item.url;
  const validFolder = (item) => item && typeof item.id === 'string' && !!item.id && typeof item.name === 'string' && !!item.name.trim();
  const canonical = (value) => {
    if (Array.isArray(value)) return value.map(canonical);
    if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
    return value;
  };
  const signature = (value) => JSON.stringify(canonical(value));
  const snapshots = (items) => new Map(items.map((item) => [item.id, signature(item)]));
  const unchanged = (item, targets) => validLink(item) && targets.get(item.id) === signature(item);
  const displayLinks = (items) => items.filter(validLink).map((item) => ({ ...item })).sort((a, b) => (Number(b.addedAt) || 0) - (Number(a.addedAt) || 0));
  const folderKey = (name) => String(name || '').trim().replace(/\s+/g, ' ').toLocaleLowerCase();

  function removal(list, predicate) {
    const removed = [];
    const next = list.filter((item, index) => {
      if (!predicate(item)) return true;
      removed.push({ item: clone(item), index });
      return false;
    });
    return { next, removed, order: list.map((item) => item?.id) };
  }

  // Insert beside surviving original neighbours. Newly captured links and native
  // bumps keep their current fields/order; an existing ID is never replaced.
  function restore(list, entry) {
    const next = [...list];
    const ids = new Set(list.map((item) => item?.id));
    let restored = 0;
    for (const { item, index } of [...entry.removed].sort((a, b) => a.index - b.index)) {
      if (ids.has(item.id)) continue;
      let insertion = -1;
      for (let i = index + 1; i < entry.order.length && insertion < 0; i += 1) {
        insertion = next.findIndex((current) => current?.id === entry.order[i]);
      }
      if (insertion < 0) {
        for (let i = index - 1; i >= 0; i -= 1) {
          const previous = next.findIndex((current) => current?.id === entry.order[i]);
          if (previous >= 0) { insertion = previous + 1; break; }
        }
      }
      // If all old neighbours disappeared, keep newly captured entries in front.
      if (insertion < 0) insertion = next.length;
      next.splice(insertion, 0, clone(item));
      ids.add(item.id);
      restored += 1;
    }
    return { next, restored };
  }

  function createStore(bridge) {
    let revision = 0;
    const changed = () => { revision += 1; };
    async function read(key) {
      try {
        // Events arriving while get is in flight invalidate that read. There is
        // no bridge CAS API; keep the final transform -> set free of other awaits.
        for (let attempt = 0; attempt < 5; attempt += 1) {
          const before = revision;
          const value = await bridge.storage.get(key);
          if (before !== revision) continue;
          if (value == null) return [];
          if (!Array.isArray(value)) throw new Error(`Saved ${key} are not a list. Use Retry to reload.`);
          return value;
        }
        throw new Error('Links are changing. Please try again.');
      } catch (error) { throw error; }
    }
    async function update(key, transform) {
      try {
        const current = await read(key);
        const result = transform(current);
        if (signature(result.next) !== signature(current)) {
          await bridge.storage.set(key, result.next);
          changed();
        }
        return result;
      } catch (error) { throw error; }
    }
    return { read, update, changed, get revision() { return revision; } };
  }
  return { clone, validLink, validFolder, signature, snapshots, unchanged, displayLinks, folderKey, removal, restore, createStore };
})();
