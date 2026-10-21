// Executes the shipped generated zsh through a mocked window.nook, never the live app.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
assert.notEqual(process.getuid(), 0, 'Permission tests must run as a normal user.');
const workspace = path.resolve(__dirname, '../..');
const fixtures = fs.mkdtempSync('/tmp/nook-cleaner-shell-');
const home = path.join(fixtures, 'home');
fs.mkdirSync(home);
const context = vm.createContext({});
const source = fs.readFileSync(path.join(workspace, 'Plugins/cleaner/shell.js'), 'utf8');
fs.writeFileSync(path.join(fixtures, 'shell.js'), source);
vm.runInContext(source + '\nglobalThis.CleanerShell = CleanerShell;', context);
const { CleanerShell } = context;
const window = { nook: { shell(command) {
  const result = spawnSync('/bin/zsh', ['-fc', command], {
    env: { ...process.env, HOME: home }, encoding: 'utf8', timeout: 30000,
  });
  assert.ifError(result.error);
  return { code: result.status, stdout: result.stdout, stderr: result.stderr };
} } };
function scan(id) {
  const response = window.nook.shell(CleanerShell.scan(id, 60));
  assert.equal(response.code, 0, response.stderr);
  assert.equal(response.stderr, '', 'Protected paths must not produce an error wall.');
  return response.stdout;
}
function file(relative, contents = 'cache contents') {
  const target = path.join(home, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, contents);
  return target;
}
const locked = path.join(home, 'Library/Caches/locked');
try {
  file('Library/Caches/allowed/cache');
  file('Library/Caches/locked/private');
  fs.chmodSync(locked, 0);
  const unreadableFile = file('Library/Caches/unreadable-file');
  fs.chmodSync(unreadableFile, 0);
  file('Library/Caches/partial/readable');
  file('Library/Caches/partial/protected/private');
  fs.chmodSync(path.join(home, 'Library/Caches/partial/protected'), 0);
  const output = scan('caches');
  assert.match(output, /TOTAL\t[1-9]\d*\t1\n/, 'An unreadable sibling must not hide the readable cache.');
  assert.match(output, /SKIPPED\t3\t3\n/);
  fs.chmodSync(locked, 0o700);
  fs.chmodSync(unreadableFile, 0o600);
  const root = path.join(home, 'Library/Caches');
  fs.chmodSync(root, 0);
  assert.match(scan('caches'), /SKIPPED\t1\t1\n/, 'An unreadable root is counted.');
  fs.chmodSync(root, 0o700);
  fs.mkdirSync(path.join(home, '.Trash'));
  fs.chmodSync(path.join(home, '.Trash'), 0);
  assert.match(scan('trash'), /UNKNOWN\n/, 'Trash stays selectable when its size cannot be read.');
  // Inspect, never execute: empty Trash must not depend on filesystem access.
  const empty = CleanerShell.clean('trash', 60);
  assert.match(empty, /tell application "Finder" to empty trash/);
  assert.doesNotMatch(empty, /cleaner_root|\.Trash/);
  // Execute generated emptying zsh only after replacing osascript with a harmless /tmp stub.
  const osascript = path.join(fixtures, 'osascript');
  fs.writeFileSync(osascript, '#!/bin/sh\nexit 0\n', { mode: 0o700 });
  const pretendEmpty = empty.replace('/usr/bin/osascript', `'${osascript}'`);
  assert.equal(window.nook.shell(pretendEmpty).stdout, 'EMPTIED\n');
  fs.writeFileSync(osascript, '#!/bin/sh\nexit 1\n');
  const deniedEmpty = window.nook.shell(pretendEmpty);
  assert.equal(deniedEmpty.code, 1);
  assert.doesNotMatch(deniedEmpty.stdout, /EMPTIED/);
  file('Downloads/old');
  const old = new Date(Date.now() - 90 * 86400000);
  fs.utimesSync(path.join(home, 'Downloads/old'), old, old);
  file('Downloads/recent');
  fs.mkdirSync(path.join(home, 'Downloads/old-folder'));
  fs.symlinkSync(path.join(home, 'Downloads/old'), path.join(home, 'Downloads/link'));
  assert.match(scan('downloads'), /TOTAL\t\d+\t1\n/);
  file('Library/Caches/Yarn/cache');
  file('Library/Caches/pip/cache');
  fs.chmodSync(path.join(home, 'Library/Caches/Yarn'), 0);
  const packages = scan('packages');
  assert.match(packages, /PART\tpip\t[1-9]\d*\t1\n/);
  assert.match(packages, /SKIPPED\t1\t1\n/);
  assert.throws(() => CleanerShell.scan('arbitrary', 60));
  assert.equal(CleanerShell.days('7; exit 1'), 60);
  console.log('PASS: readable siblings, protected roots, unknown Trash, fixed roots, package isolation, download eligibility');
} finally {
  for (const relative of ['Library/Caches', 'Library/Caches/locked', 'Library/Caches/partial/protected', 'Library/Caches/Yarn', '.Trash']) {
    try { fs.chmodSync(path.join(home, relative), 0o700); } catch {}
  }
  fs.rmSync(fixtures, { recursive: true, force: true }); // generated /tmp fixtures only
}
