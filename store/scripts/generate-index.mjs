#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import { resolve, relative, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { pluginDirectories, validatePlugin, treeSHA, packageSHA256 } from './validate.mjs';

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const indexPath = join(root, 'index.json');
let previous = [];
try { previous = JSON.parse(await readFile(indexPath, 'utf8')); } catch { /* First generation. */ }
const entries = [];
for (const directory of await pluginDirectories(root)) {
  const { errors, warnings, manifest, metadata } = await validatePlugin(directory);
  if (errors.length) throw new Error(`${directory}:\n${errors.join('\n')}`);
  warnings.forEach((w) => console.warn(`${manifest.id}: ${w}`));
  const sha = await treeSHA(directory);
  const prior = previous.find((p) => p.id === manifest.id && p.sha === sha);
  let updatedAt = prior?.updatedAt;
  if (!updatedAt) {
    try {
      updatedAt = execFileSync('git', ['log', '-1', '--format=%cI', '--', relative(root, directory)], { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    } catch { /* Initial export before the standalone repository exists. */ }
  }
  if (!updatedAt) updatedAt = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  entries.push({ id: manifest.id, name: manifest.name, description: metadata.description,
    author: metadata.author, version: metadata.version, symbol: manifest.symbol ?? 'puzzlepiece.extension.fill',
    tags: metadata.tags, screenshots: metadata.screenshots, path: `plugins/${manifest.id}`, sha, sha256: await packageSHA256(directory), default: metadata.default === true, updatedAt });
}
entries.sort((a, b) => a.id.localeCompare(b.id, 'en'));
await writeFile(indexPath, `${JSON.stringify(entries, null, 2)}\n`);
console.log(`Generated ${entries.length} plugin(s) in index.json`);
