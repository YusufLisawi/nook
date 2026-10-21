#!/usr/bin/env node
// Dependency-free port of cli/swift/main.swift's `nook validate`, plus Store packaging rules.
import { readFile, readdir, lstat } from 'node:fs/promises';
import { resolve, relative, basename, extname, join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

export const validID = (id) => typeof id === 'string' && /^[a-z0-9][a-z0-9-]{0,79}$/.test(id) && !/\s/.test(id);
export const validVersion = (version) => typeof version === 'string' && /^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(version) && !/\s/.test(version);
export const safePath = (path) => typeof path === 'string' && path.length > 0 && Buffer.byteLength(path) <= 500 && !/[\\:\x00-\x1f\x7f]/.test(path)
  && path.split('/').every((part) => part && !part.startsWith('.'));
const nonempty = (value) => typeof value === 'string' && value.trim().length > 0;
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

export async function packageFiles(root) {
  const files = [];
  const seen = new Set();
  let total = 0;
  if (!(await lstat(root)).isDirectory()) throw new Error('Plugin folder must be a real directory, not a symlink.');
  async function walk(directory) {
    for (const name of await readdir(directory)) {
      const file = join(directory, name);
      const path = relative(root, file).split('\\').join('/');
      const normalized = path.normalize('NFC').toLowerCase();
      if (!safePath(path) || seen.has(normalized)) throw new Error(`Unsafe or duplicate path: ${path}`);
      seen.add(normalized);
      const stat = await lstat(file);
      if (stat.isSymbolicLink()) throw new Error(`Symlinks are not allowed: ${path}`);
      if (stat.isDirectory()) { await walk(file); continue; }
      if (!stat.isFile() || (stat.mode & 0o111) || stat.size > 5_000_000) throw new Error(`Files must be regular, non-executable files up to 5 MB: ${path}`);
      files.push({ path, file, size: stat.size });
      total += stat.size;
      if (files.length > 200 || total > 20_000_000) throw new Error('Plugins are limited to 200 files and 20 MB.');
    }
  }
  await walk(root);
  return files.sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)));
}

export const objectSHA = (type, data) => createHash('sha1').update(`${type} ${data.length}\0`).update(data).digest('hex');
export async function treeSHA(root) {
  const files = await packageFiles(root);
  async function tree(prefix) {
    const children = new Map();
    for (const file of files.filter((f) => f.path.startsWith(prefix))) {
      const rest = file.path.slice(prefix.length);
      const name = rest.split('/')[0];
      children.set(name, rest.includes('/') ? { directory: true } : file);
    }
    const sorted = [...children].sort(([an, a], [bn, b]) => Buffer.compare(Buffer.from(an + (a.directory ? '/' : '')), Buffer.from(bn + (b.directory ? '/' : ''))));
    const body = [];
    for (const [name, child] of sorted) {
      const sha = child.directory ? await tree(`${prefix}${name}/`) : objectSHA('blob', await readFile(child.file));
      body.push(Buffer.from(`${child.directory ? '40000' : '100644'} ${name}\0`), Buffer.from(sha, 'hex'));
    }
    return objectSHA('tree', Buffer.concat(body));
  }
  return tree('');
}

export async function validatePlugin(root) {
  root = resolve(root);
  const errors = [], warnings = [];
  const error = (message) => errors.push(message);
  let files, manifest, metadata;
  try { files = await packageFiles(root); } catch (e) { return { errors: [e.message], warnings }; }
  try { manifest = JSON.parse(await readFile(join(root, 'plugin.json'), 'utf8')); }
  catch { return { errors: ['plugin.json is missing or is not valid JSON'], warnings }; }
  if (!isObject(manifest)) return { errors: ['plugin.json must contain an object'], warnings };
  for (const key of ['id', 'name']) if (!nonempty(manifest[key])) error(`plugin.json needs "${key}"`);
  if (!validID(manifest.id)) error('id must be lowercase letters, digits and dashes, at most 80 characters');
  if (manifest.id !== basename(root)) error('folder name must match plugin id');
  const paths = new Set(files.map((f) => f.path));
  const entry = manifest.entry ?? 'index.html';
  for (const key of ['entry', 'symbol', 'icon']) if (manifest[key] !== undefined && !nonempty(manifest[key])) error(`${key} must be a nonempty string`);
  if (!safePath(entry) || !paths.has(entry)) error('entry file is missing or unsafe');
  if (manifest.order !== undefined && (!Number.isInteger(manifest.order) || manifest.order < -2147483648 || manifest.order > 2147483647)) error('order must be an integer between -2147483648 and 2147483647');
  if (manifest.height !== undefined && (typeof manifest.height !== 'number' || manifest.height < 80 || manifest.height > 400)) error('height must be a number between 80 and 400');
  if (manifest.symbol === undefined) warnings.push('no "symbol" — the dock shows a puzzle piece');
  else if (!nonempty(manifest.symbol)) error('symbol must be a nonempty SF Symbol name');
  if (manifest.icon !== undefined && (!safePath(manifest.icon) || !paths.has(manifest.icon))) error('icon is missing or unsafe');
  const keys = new Set();
  if (manifest.settings !== undefined) {
    if (!Array.isArray(manifest.settings) || !manifest.settings.every(isObject)) error('settings must be an array of objects');
    else manifest.settings.forEach((s, i) => {
      if (!nonempty(s.key) || !nonempty(s.label)) error(`settings[${i}] needs key and label`);
      if (!['toggle', 'text', 'secret', 'textarea', 'number', 'select', 'color'].includes(s.type)) error(`settings[${i}] has an invalid type`);
      if (s.type === 'select' && (!Array.isArray(s.options) || !s.options.length)) error(`settings[${i}] select needs options`);
      if (s.options != null && (!Array.isArray(s.options) || !s.options.every((v) => typeof v === 'string') || new Set(s.options).size !== s.options.length)) error(`settings[${i}] options must be unique strings`);
      if (s.help != null && typeof s.help !== 'string') error(`settings[${i}] help must be text`);
      for (const field of ['min', 'max', 'step']) if (s[field] != null && (typeof s[field] !== 'number' || !Number.isFinite(s[field]))) error(`settings[${i}] ${field} must be a finite number`);
      if (typeof s.min === 'number' && typeof s.max === 'number' && s.min > s.max) error(`settings[${i}] min must not exceed max`);
      if (typeof s.step === 'number' && s.step <= 0) error(`settings[${i}] step must be positive`);
      if (s.default != null && !['string', 'number', 'boolean'].includes(typeof s.default)) error(`settings[${i}] defaults must be JSON scalars`);
      if (keys.has(s.key)) error(`settings[${i}] duplicate key`);
      keys.add(s.key);
    });
  }
  let allCode = '', size = 0;
  for (const file of files.filter((f) => /\.(html|css|js|mjs)$/i.test(f.path))) {
    const code = await readFile(file.file, 'utf8');
    allCode += code;
    size += file.size;
    if (/<(script|link)[^>]+(src|href)\s*=\s*["']\s*(https?:|\/\/)/i.test(code) || /@import\s+(url\()?\s*["']?\s*(https?:|\/\/)/i.test(code)) error(`${file.path}: loads code/styles from the network — bundle them locally`);
    if (/\bfetch\(\s*["'`]https?:/i.test(code)) warnings.push(`${file.path}: uses fetch() for http — use nook.fetch`);
    if (/(html|body)\s*\{[^}]*background(-color)?\s*:\s*(#fff|white|rgb\(255)/i.test(code)) error(`${file.path}: page background must stay transparent`);
    if (code.split('}').some((rule) => /border-left\s*:\s*[3-9]px\s+solid\s+(?!transparent)/i.test(rule) && !/width\s*:\s*0/i.test(rule))) warnings.push(`${file.path}: thick left border — avoid coloured edge stripes`);
    if (code.includes('localStorage.')) warnings.push(`${file.path}: prefer nook.storage to localStorage`);
  }
  if (keys.size && !/nook\.settings\.get|nook\.on\(\s*['"]settings/i.test(allCode)) warnings.push('declares settings but never reads them');
  if (size > 1_500_000) warnings.push(`code is ${(size / 1e6).toFixed(1)} MB — keep plugins light`);
  try { metadata = JSON.parse(await readFile(join(root, 'store.json'), 'utf8')); }
  catch { error('store.json is missing or is not valid JSON'); }
  if (!isObject(metadata)) error('store.json must contain an object');
  else {
    for (const key of ['description', 'author', 'version']) if (!nonempty(metadata[key])) error(`store.json needs ${key}`);
    if (!validVersion(metadata.version)) error('store.json version must be major.minor.patch, optionally with a prerelease suffix');
    if (manifest.version !== undefined && manifest.version !== metadata.version) error('plugin.json version must match store.json');
    if (!Array.isArray(metadata.tags) || !metadata.tags.every(nonempty)) error('store.json tags must be an array of nonempty strings');
    if (!Array.isArray(metadata.screenshots)) error('store.json screenshots must be an array of local paths');
    else for (const path of metadata.screenshots) if (!safePath(path) || !paths.has(path)) error(`Missing or unsafe screenshot: ${path}`);
  }
  return { errors, warnings, manifest, metadata };
}

export async function pluginDirectories(root) {
  return (await readdir(join(root, 'plugins'), { withFileTypes: true })).map((entry) => join(root, 'plugins', entry.name)).sort();
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
  try {
    const targets = process.argv.slice(2).length ? process.argv.slice(2).map((p) => resolve(p)) : await pluginDirectories(root);
    let failures = 0;
    for (const target of targets) {
      const result = await validatePlugin(target);
      console.log(`${result.errors.length ? '✗' : '✓'} ${basename(target)}`);
      result.errors.forEach((e) => console.error(`  error: ${e}`));
      result.warnings.forEach((w) => console.warn(`  warn: ${w}`));
      if (result.errors.length) failures++;
    }
    process.exitCode = failures ? 1 : 0;
  } catch (e) { console.error(e.message); process.exitCode = 1; }
}
