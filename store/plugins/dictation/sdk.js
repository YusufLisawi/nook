(() => {
 const n = window.nook;
 const originalOpen = n.open;
 n.open = url => typeof url === 'string' && url === 'nook://settings/' + n.plugin.id ? n.settings.open() : /^https?:|^mailto:/.test(url) ? n.host.call('network.open',{url}) : originalOpen(url);
 n.dictation = Object.fromEntries(["history", "retry", "remove", "copy", "paste", "clear", "state", "toggle"].map(fn => [fn, (...args) => n.native.call('dictation.' + fn, {args})]));
 for (const event of ["dictation"]) n.native.on(event, data => n._emit(event, data));
 n.native.on('ready', () => n._emit('open', {}));
})();
