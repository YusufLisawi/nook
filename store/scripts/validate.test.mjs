import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, symlink, chmod, readFile, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { validatePlugin, treeSHA, validID, validVersion } from './validate.mjs';

async function fixture(run) {
  const temporary = await mkdtemp(join(tmpdir(), 'nook-store-validation-'));
  const root = join(temporary, 'sample');
  await mkdir(root);
  const manifest = { id: 'sample', name: 'Sample', symbol: 'sparkles', height: 210 };
  const metadata = { description: 'A small example.', author: 'contributor', version: '1.0.0', tags: ['offline'], screenshots: [] };
  const json = (name, data) => writeFile(join(root, name), JSON.stringify(data));
  await json('plugin.json', manifest); await json('store.json', metadata);
  await writeFile(join(root, 'index.html'), '<main class="nk-root"></main>');
  try { await run({ root, temporary, manifest, metadata, json }); }
  finally { await rm(temporary, { recursive: true, force: true }); }
}

test('valid package and Git tree hash match Git, including nested and Unicode paths', async () => fixture(async ({ root, temporary }) => {
  await mkdir(join(root, 'assets'));
  await writeFile(join(root, 'assets', 'é.txt'), 'hello');
  await writeFile(join(root, 'assets.txt'), 'sibling');
  assert.deepEqual((await validatePlugin(root)).errors, []);
  execFileSync('git', ['init', '-q', temporary]);
  execFileSync('git', ['-C', temporary, 'add', '--', 'sample']);
  const tree = execFileSync('git', ['-C', temporary, 'write-tree'], { encoding: 'utf8' }).trim();
  const expected = execFileSync('git', ['-C', temporary, 'rev-parse', `${tree}:sample`], { encoding: 'utf8' }).trim();
  assert.equal(await treeSHA(root), expected);
}));

const cases = [
  ['invalid ID', async (f) => { f.manifest.id = '../escape'; await f.json('plugin.json', f.manifest); }],
  ['invalid height', async (f) => { f.manifest.height = true; await f.json('plugin.json', f.manifest); }],
  ['invalid order', async (f) => { f.manifest.order = 'first'; await f.json('plugin.json', f.manifest); }],
  ['fractional order', async (f) => { f.manifest.order = 1.5; await f.json('plugin.json', f.manifest); }],
  ['non-string entry', async (f) => { f.manifest.entry = false; await f.json('plugin.json', f.manifest); }],
  ['non-string symbol', async (f) => { f.manifest.symbol = 3; await f.json('plugin.json', f.manifest); }],
  ['unsafe entry', async (f) => { f.manifest.entry = '../index.html'; await f.json('plugin.json', f.manifest); }],
  ['missing icon', async (f) => { f.manifest.icon = 'missing.png'; await f.json('plugin.json', f.manifest); }],
  ['duplicate settings', async (f) => { f.manifest.settings = [1, 2].map(() => ({ key: 'x', label: 'X', type: 'toggle' })); await f.json('plugin.json', f.manifest); }],
  ['select without options', async (f) => { f.manifest.settings = [{ key: 'x', label: 'X', type: 'select' }]; await f.json('plugin.json', f.manifest); }],
  ['non-string options', async (f) => { f.manifest.settings = [{ key: 'x', label: 'X', type: 'select', options: [1] }]; await f.json('plugin.json', f.manifest); }],
  ['inverted slider range', async (f) => { f.manifest.settings = [{ key: 'x', label: 'X', type: 'number', min: 5, max: 1 }]; await f.json('plugin.json', f.manifest); }],
  ['invalid slider step', async (f) => { f.manifest.settings = [{ key: 'x', label: 'X', type: 'number', step: 0 }]; await f.json('plugin.json', f.manifest); }],
  ['non-scalar default', async (f) => { f.manifest.settings = [{ key: 'x', label: 'X', type: 'text', default: {} }]; await f.json('plugin.json', f.manifest); }],
  ['CDN script', async (f) => writeFile(join(f.root, 'index.html'), '<script src = "https://example.com/a.js"></script>')],
  ['CDN CSS import', async (f) => writeFile(join(f.root, 'style.css'), '@import url("//example.com/a.css");')],
  ['opaque page', async (f) => writeFile(join(f.root, 'style.css'), 'body { background: white; }')],
  ['symlink', async (f) => symlink('/etc/hosts', join(f.root, 'linked.txt'))],
  ['hidden file', async (f) => writeFile(join(f.root, '.secrets'), 'no secrets')],
  ['executable', async (f) => { await writeFile(join(f.root, 'script.sh'), 'exit 0'); await chmod(join(f.root, 'script.sh'), 0o755); }],
  ['bad metadata', async (f) => f.json('store.json', { ...f.metadata, version: 'latest' })],
  ['missing screenshot', async (f) => f.json('store.json', { ...f.metadata, screenshots: ['missing.png'] })],
  ['version mismatch', async (f) => f.json('plugin.json', { ...f.manifest, version: '2.0.0' })],
  ['non-object manifest', async (f) => f.json('plugin.json', [])],
];
for (const [name, mutate] of cases) test(`rejects ${name}`, async () => fixture(async (f) => {
  await mutate(f);
  assert.ok((await validatePlugin(f.root)).errors.length > 0);
}));

test('IDs and versions reject trailing line terminators', () => {
  for (const suffix of ['\n', '\r', '\u2028', '\u2029']) {
    assert.equal(validID(`sample${suffix}`), false);
    assert.equal(validVersion(`1.0.0${suffix}`), false);
  }
});

test('ports nook validate advisory UI checks', async () => fixture(async ({ root, manifest, json }) => {
  delete manifest.symbol;
  manifest.settings = [{ key: 'label', label: 'Label', type: 'text' }];
  await json('plugin.json', manifest);
  await writeFile(join(root, 'main.js'), "localStorage.getItem('x'); fetch('https://example.com');");
  await writeFile(join(root, 'style.css'), '.row { border-left: 4px solid orange; }');
  const result = await validatePlugin(root);
  assert.deepEqual(result.errors, []);
  assert.equal(result.warnings.length, 5);
}));

test('the shipped example validates without warnings', async () => {
  const root = resolve(new URL('../plugins/word-count/', import.meta.url).pathname);
  const result = await validatePlugin(root);
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.warnings, []);
});

test('generator produces a complete, stable catalog without an existing Git repository', async () => {
  const temporary = await mkdtemp(join(tmpdir(), 'nook-store-generator-'));
  try {
    await cp(new URL('../plugins/', import.meta.url), join(temporary, 'plugins'), { recursive: true });
    await mkdir(join(temporary, 'scripts'));
    for (const name of ['validate.mjs', 'generate-index.mjs']) await cp(new URL(name, import.meta.url), join(temporary, 'scripts', name));
    execFileSync(process.execPath, [join(temporary, 'scripts/generate-index.mjs')]);
    const first = await readFile(join(temporary, 'index.json'), 'utf8');
    const index = JSON.parse(first);
    assert.equal(index.length, 1);
    assert.equal(index[0].path, 'plugins/word-count');
    assert.equal(index[0].sha, await treeSHA(join(temporary, 'plugins/word-count')));
    assert.ok(index[0].author && index[0].updatedAt && Array.isArray(index[0].screenshots));
    execFileSync(process.execPath, [join(temporary, 'scripts/generate-index.mjs')]);
    assert.equal(await readFile(join(temporary, 'index.json'), 'utf8'), first);
  } finally { await rm(temporary, { recursive: true, force: true }); }
});
