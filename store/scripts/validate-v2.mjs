// Keep the manifest contract aligned with Nook/Core/PluginEngine/PluginManifestV2.swift.
const permissions = new Set(['files', 'clipboard', 'accessibility', 'microphone', 'network', 'shell', 'ai', 'background', 'hotkeys', 'notifications', 'launcher', 'windows', 'secrets']);
const sections = new Set(['hotkeys', 'launcherItems', 'answerProviders', 'settings', 'menuBar', 'notchActivity', 'urlHandlers', 'backgroundJobs']);
const object = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const path = v => typeof v === 'string' && v.length > 0 && !/[\\:\0]/.test(v) && v.split('/').every(p => p && p !== '.' && p !== '..');

export function validateV2(manifest, files) {
  const errors = [];
  const version = manifest.apiVersion ?? 1;
  if (![1, 2].includes(version)) return ['apiVersion must be 1 or 2'];
  if (version === 1) return manifest.native != null || manifest.contributes != null ? ['native and contributes require apiVersion: 2'] : [];
  const declared = new Set();
  function checkPermissions(list) {
    if (list === undefined) return;
    if (!Array.isArray(list) || new Set(list).size !== list.length || !list.every(p => permissions.has(p))) errors.push('Unknown or duplicate plugin permission');
    else for (const item of list) declared.add(item);
  }
  checkPermissions(manifest.permissions);
  if (manifest.native !== undefined) {
    const n = manifest.native;
    if (!object(n)) errors.push('native must be an object');
    else {
      checkPermissions(n.permissions);
      if (n.background !== undefined && typeof n.background !== 'boolean') errors.push('native.background must be a boolean');
      if (n.background && !declared.has('background')) errors.push('A background helper must declare background permission');
      const run = n.run ?? n.command?.run;
      if (n.command !== undefined && n.run !== undefined) errors.push('Choose native.command or native.run');
      if (typeof n.command === 'string') {
        if (run !== undefined) errors.push('Choose native.command or native.run');
        if (!path(n.command)) errors.push('native.command must stay inside the plugin');
        const candidates = [n.command, n.command.replace(/^bin\//, 'bin/arm64/'), n.command.replace(/^bin\//, 'bin/x86_64/')];
        if (!files.some(f => candidates.includes(f.path) && f.executable)) errors.push('Build the native helper before packaging');
      } else if (!Array.isArray(run) || run.length < 2 || run.length > 64 || !run.every(s => typeof s === 'string' && s.length && !s.includes('\0')) || !['node', 'python3', 'ruby', 'swift', 'bash', 'sh'].includes(run[0]) || !path(run[1]) || run[1].startsWith('-') || !files.some(f => f.path === run[1])) errors.push('native.run must name an interpreter and an existing relative script');
    }
  }
  if (manifest.contributes !== undefined) {
    if (!object(manifest.contributes)) errors.push('contributes must be an object');
    else for (const [section, list] of Object.entries(manifest.contributes)) {
      if (!sections.has(section) || !Array.isArray(list) || list.length > 100 || !list.every(object)) { errors.push(`Invalid contributes.${section}`); continue; }
      if (list.some(row => typeof row.id !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(row.id) || /[\r\n]/.test(row.id)) || new Set(list.map(row => row.id)).size !== list.length) errors.push(`contributes.${section} needs unique ids`);
      for (const row of list) {
        const nonempty = key => typeof row[key] === 'string' && row[key].trim().length;
        if (section === 'hotkeys' && (!Number.isInteger(row.keyCode) || row.keyCode < 0 || row.keyCode > 127 || !Number.isSafeInteger(row.modifiers) || !(row.modifiers & 0x1C0000))) errors.push('Hotkeys need keyCode and Command/Control/Option CGEventFlags modifiers');
        if (section === 'launcherItems' && !nonempty('title')) errors.push('Launcher items need a title');
        if (section === 'answerProviders' && (!nonempty('prefix') || !nonempty('method') || !manifest.native)) errors.push('Answer providers need prefix, method and a native helper');
        if (section === 'backgroundJobs' && (typeof row.interval !== 'number' || !Number.isFinite(row.interval) || row.interval < 1 || row.interval > 86400)) errors.push('Background jobs need interval (1–86400 seconds)');
      }
      const permission = { hotkeys: 'hotkeys', launcherItems: 'launcher', answerProviders: 'launcher', backgroundJobs: 'background' }[section];
      if (list.length && permission && !declared.has(permission)) errors.push(`${section} requires ${permission} permission`);
    }
  }
  return errors;
}
