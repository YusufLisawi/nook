(() => {
 const n = window.nook;
 const originalOpen = n.open;
 n.open = url => typeof url === 'string' && url === 'nook://settings/' + n.plugin.id ? n.settings.open() : /^https?:|^mailto:/.test(url) ? n.host.call('network.open',{url}) : originalOpen(url);
 n.commands = Object.fromEntries(["list", "save", "remove", "run", "recordHotkey", "clearHotkey", "models", "lastRun"].map(fn => [fn, (...args) => n.native.call('commands.' + fn, {args})]));
 for (const event of ["commands", "commandRun"]) n.native.on(event, data => n._emit(event, data));
 n.native.on('ready', () => n._emit('open', {}));
})();
