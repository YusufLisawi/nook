// Optional read-only reproduction: generated scan scripts only. No clean API is exposed or called.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(path.resolve(__dirname, '../../Plugins/cleaner/shell.js'), 'utf8')
  + '\nglobalThis.scan = CleanerShell.scan;', context);
const window = { nook: { shell(command) {
  const result = spawnSync('/bin/zsh', ['-fc', command], { encoding: 'utf8', env: process.env, timeout: 120000 });
  if (result.error) throw result.error;
  return { code: result.status, stdout: result.stdout, stderr: result.stderr };
} } };
for (const id of ['caches', 'logs', 'trash']) {
  const result = window.nook.shell(context.scan(id, 60));
  console.log(JSON.stringify({ id, ...result }));
  if (result.code !== 0) process.exitCode = 1;
}
