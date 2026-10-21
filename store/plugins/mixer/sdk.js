(() => {
 const n = window.nook;
 const originalOpen = n.open;
 n.open = url => typeof url === 'string' && url === 'nook://settings/' + n.plugin.id ? n.settings.open() : /^https?:|^mailto:/.test(url) ? n.host.call('network.open',{url}) : originalOpen(url);
 n.audio = Object.fromEntries(["state", "setDefault", "setDeviceVolume", "setDeviceMute", "setPreferred", "setAppVolume", "setAppMute", "resetApp", "openPrivacy"].map(fn => [fn, (...args) => n.native.call('audio.' + fn, {args})]));
 for (const event of ["audio"]) n.native.on(event, data => n._emit(event, data));
 n.native.on('ready', () => n._emit('open', {}));
})();
