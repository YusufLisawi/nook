#!/usr/bin/env bun
// nook — CLI for Nook, the notch app. Build, check and drive plugins without rebuilding the app.
import { existsSync, readFileSync, readdirSync, mkdirSync, cpSync, writeFileSync, statSync, realpathSync } from "node:fs";
import { join, dirname, basename, resolve } from "node:path";
import { homedir } from "node:os";
import { spawnSync } from "node:child_process";

const HOME = homedir();
const SUPPORT = join(HOME, "Library/Application Support/Nook");
const USER_PLUGINS = join(SUPPORT, "Plugins");
const DATA = join(SUPPORT, "Data");
const LOG = join(HOME, "Library/Logs/Nook/plugins.log");
const REPO = resolve(dirname(realpathSync(import.meta.path)), "..");
const BUNDLED = existsSync("/Applications/Nook.app/Contents/Resources/Plugins")
  ? "/Applications/Nook.app/Contents/Resources/Plugins" : join(REPO, "Plugins");
const MAX_HEIGHT = 400;

const [cmd = "help", ...args] = process.argv.slice(2);
const flag = (name: string, fallback?: string) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : fallback;
};
const has = (name: string) => args.includes(`--${name}`);
const die = (msg: string): never => { console.error(`✗ ${msg}`); process.exit(1); };
const readJSON = (p: string) => JSON.parse(readFileSync(p, "utf8"));
const openURL = (url: string) => spawnSync("open", ["-g", url]);

type Plugin = { id: string; name: string; symbol?: string; order?: number; height?: number; entry?: string; dir: string; source: string };

function plugins(): Plugin[] {
  const byId = new Map<string, Plugin>();
  for (const [root, source] of [[BUNDLED, "bundled"], [USER_PLUGINS, "user"]] as const) {
    if (!existsSync(root)) continue;
    for (const name of readdirSync(root)) {
      const manifest = join(root, name, "plugin.json");
      if (!existsSync(manifest)) continue;
      try {
        const m = readJSON(manifest);
        byId.set(m.id, { ...m, dir: join(root, name), source: byId.has(m.id) ? "user (overrides bundled)" : source });
      } catch { byId.set(name, { id: name, name: "⚠ bad plugin.json", dir: join(root, name), source }); }
    }
  }
  return [...byId.values()].sort((a, b) => (a.order ?? 100) - (b.order ?? 100));
}

function findPlugin(idOrPath?: string): Plugin {
  if (!idOrPath) die("Give a plugin id or folder path");
  if (existsSync(join(resolve(idOrPath!), "plugin.json"))) {
    const dir = resolve(idOrPath!);
    return { ...readJSON(join(dir, "plugin.json")), dir, source: "path" };
  }
  return plugins().find((p) => p.id === idOrPath) ?? die(`No plugin "${idOrPath}". Try: nook list`);
}

function validate(p: Plugin): { errors: string[]; warnings: string[] } {
  const errors: string[] = [], warnings: string[] = [];
  let m: any;
  try { m = readJSON(join(p.dir, "plugin.json")); } catch (e) { return { errors: [`plugin.json is not valid JSON: ${e}`], warnings }; }
  for (const key of ["id", "name"]) if (!m[key]) errors.push(`plugin.json needs "${key}"`);
  if (m.id && !/^[a-z0-9][a-z0-9-]*$/.test(m.id)) errors.push(`id "${m.id}" must be lowercase letters, digits and dashes`);
  if (m.id && m.id !== basename(p.dir)) warnings.push(`folder name "${basename(p.dir)}" differs from id "${m.id}"`);
  const entry = m.entry ?? "index.html";
  if (!existsSync(join(p.dir, entry))) errors.push(`entry file "${entry}" is missing`);
  if (m.height !== undefined && (typeof m.height !== "number" || m.height < 80 || m.height > MAX_HEIGHT)) errors.push(`height must be a number between 80 and ${MAX_HEIGHT}`);
  if (!m.symbol) warnings.push(`no "symbol" — the dock will show a puzzle piece. Pick an SF Symbol name (e.g. "sparkles")`);
  if (m.icon && !existsSync(join(p.dir, m.icon))) errors.push(`icon "${m.icon}" is missing`);
  const files = readdirSync(p.dir).filter((f) => /\.(html|css|js|mjs)$/.test(f));
  for (const f of files) {
    const text = readFileSync(join(p.dir, f), "utf8");
    if (/<(script|link)[^>]+(src|href)=["']https?:/i.test(text) || /@import\s+(url\()?["']?https?:/i.test(text))
      errors.push(`${f}: loads code/styles from the network — bundle it in the folder (plugins must work offline)`);
    if (/\bfetch\(\s*["'`]https?:/.test(text)) warnings.push(`${f}: uses fetch() for http — use nook.fetch (no CORS limits)`);
    if (/(html|body)\s*\{[^}]*background(-color)?\s*:\s*(#fff|white|rgb\(255)/i.test(text)) errors.push(`${f}: page background must stay transparent (the notch is black)`);
    // Coloured edge stripe = a thick left border on a real box (skip zero-size CSS triangles).
    if ((text.match(/\{[^}]*\}/g) ?? []).some((rule) => /border-left\s*:\s*[3-9]px\s+solid\s+(?!transparent)/i.test(rule) && !/width\s*:\s*0/.test(rule))) warnings.push(`${f}: thick left border — Nook style avoids coloured edge stripes; tint the background instead`);
    if (/localStorage\./.test(text)) warnings.push(`${f}: localStorage works, but nook.storage survives reinstalls and is readable with \`nook storage\``);
    if (/<input[^>]*>/i.test(text) && f.endsWith(".html") && !/nk-input|class=/.test(text)) warnings.push(`${f}: unstyled <input> — use class="nk-input"`);
  }
  const size = files.reduce((n, f) => n + statSync(join(p.dir, f)).size, 0);
  if (size > 1_500_000) warnings.push(`code is ${(size / 1e6).toFixed(1)} MB — keep plugins light, the notch should open instantly`);
  return { errors, warnings };
}

const help = `nook — build and drive Nook plugins (no app rebuild needed)

  nook list [--json]              all plugins (bundled + yours), in dock order
  nook new <id> [--name N] [--symbol S] [--height H] [--order O]
                                  scaffold a plugin in your Plugins folder (live immediately)
  nook validate [id|path]         check a plugin (or all) against the rules
  nook eject <id>                 copy a bundled plugin into your folder so you can change it
  nook open <id> | toggle <id>    show a tab in the notch under the mouse
  nook close | reload | settings  close notches · reload all plugins · open Settings
  nook logs [id] [-f]             plugin console.log / errors (-f to follow)
  nook storage <id> [key]         read a plugin's saved data
  nook path [id]                  where plugins live (or one plugin's folder)
  nook api                        the window.nook bridge reference
  nook guide                      UI guidelines + patterns (the notch vibe)
  nook limits                     what plugins can and can't do`;

switch (cmd) {
  case "help": case "-h": case "--help": console.log(help); break;

  case "list": {
    const list = plugins();
    if (has("json")) { console.log(JSON.stringify(list, null, 2)); break; }
    for (const p of list) console.log(`${String(p.order ?? 100).padStart(3)}  ${p.id.padEnd(16)} ${p.name.padEnd(16)} ${(p.symbol ?? "").padEnd(34)} ${p.source}`);
    break;
  }

  case "path": console.log(args[0] ? findPlugin(args[0]).dir : USER_PLUGINS); break;

  case "new": {
    const id = args[0] ?? die("Usage: nook new <id> [--name N] [--symbol S] [--height H]");
    if (!/^[a-z0-9][a-z0-9-]*$/.test(id)) die("id must be lowercase letters, digits and dashes");
    const dir = join(USER_PLUGINS, id);
    if (existsSync(dir)) die(`${dir} already exists`);
    if (plugins().some((p) => p.id === id)) die(`id "${id}" is taken (nook list)`);
    const name = flag("name", id.replace(/(^|-)(\w)/g, (_, s, c) => (s ? " " : "") + c.toUpperCase()))!;
    const vars: Record<string, string> = {
      __ID__: id, __NAME__: name, __SYMBOL__: flag("symbol", "sparkles")!,
      __HEIGHT__: flag("height", "210")!, __ORDER__: flag("order", "100")!,
    };
    mkdirSync(dir, { recursive: true });
    const template = join(REPO, "cli/template");
    for (const f of readdirSync(template)) {
      let text = readFileSync(join(template, f), "utf8");
      for (const [k, v] of Object.entries(vars)) text = text.replaceAll(k, v);
      writeFileSync(join(dir, f), text);
    }
    console.log(`✓ Created ${dir}\n  It's live in the notch now. Edit main.js / index.html and it reloads on save.\n  nook open ${id}   ·   nook logs ${id} -f   ·   nook validate ${id}`);
    break;
  }

  case "validate": {
    const targets = args[0] ? [findPlugin(args[0])] : plugins();
    let failed = 0;
    for (const p of targets) {
      const { errors, warnings } = validate(p);
      const mark = errors.length ? "✗" : warnings.length ? "!" : "✓";
      console.log(`${mark} ${p.id}  (${p.dir})`);
      errors.forEach((e) => console.log(`    error: ${e}`));
      warnings.forEach((w) => console.log(`    warn:  ${w}`));
      if (errors.length) failed++;
    }
    process.exit(failed ? 1 : 0);
  }

  case "eject": {
    const p = findPlugin(args[0]);
    const dest = join(USER_PLUGINS, p.id);
    if (existsSync(dest)) die(`${dest} already exists — that's your copy`);
    cpSync(p.dir, dest, { recursive: true });
    console.log(`✓ Copied to ${dest}. Your copy now overrides the bundled one.`);
    break;
  }

  case "open": case "toggle":
    if (!args[0]) die(`Usage: nook ${cmd} <id>`);
    openURL(`nook://${cmd}/${args[0]}`);
    break;
  case "close": case "reload": case "settings": openURL(`nook://${cmd}`); break;

  case "logs": {
    if (!existsSync(LOG)) { console.log("No plugin logs yet."); break; }
    const id = args.find((a) => !a.startsWith("-"));
    const grep = id ? ["--line-buffered", "-F", `[${id}]`] : [];
    if (args.includes("-f")) spawnSync("sh", ["-c", `tail -n 30 -f "${LOG}"${id ? ` | grep ${grep.map((g) => `'${g}'`).join(" ")}` : ""}`], { stdio: "inherit" });
    else {
      const lines = readFileSync(LOG, "utf8").trim().split("\n").filter((l) => !id || l.includes(`[${id}]`));
      console.log(lines.slice(-50).join("\n") || "No logs for that plugin.");
    }
    break;
  }

  case "storage": {
    const id = args[0] ?? die("Usage: nook storage <id> [key]");
    const file = join(DATA, `${id}.json`);
    if (!existsSync(file)) { console.log("{}"); break; }
    const data = readJSON(file);
    console.log(JSON.stringify(args[1] ? data[args[1]] ?? null : data, null, 2));
    break;
  }

  case "api": console.log(readFileSync(join(REPO, "PLUGINS.md"), "utf8")); break;
  case "guide": console.log(readFileSync(join(REPO, "docs/UI-GUIDELINES.md"), "utf8")); break;
  case "limits": console.log(readFileSync(join(REPO, "docs/LIMITS.md"), "utf8")); break;

  default: die(`Unknown command "${cmd}". Run: nook help`);
}
