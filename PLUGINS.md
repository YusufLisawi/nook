# Nook plugins

A plugin is a folder. Nook loads it at runtime — no app rebuild.

```
~/Library/Application Support/Nook/Plugins/<id>/     ← yours (overrides a bundled plugin with the same id)
Nook.app/Contents/Resources/Plugins/<id>/            ← bundled
  plugin.json
  index.html        (plus any .js / .css / images next to it)
```

Edit a file and Nook reloads the plugin within a second (folder is watched).

## plugin.json

```json
{
  "id": "notes",              // unique, folder name
  "name": "Notes",
  "symbol": "note.text",      // SF Symbol for the tab dock
  "icon": "icon.png",         // optional, shown in Settings
  "entry": "index.html",
  "order": 40,                // default dock position (lower = left); users can drag icons to reorder
  "height": 210,              // content height in points when this tab is open (default 210, min 80, max 400)
  "settings": [               // optional: user options — Nook builds the form for you (see "Settings" below)
    { "key": "showStats", "label": "Show stats", "type": "toggle", "default": true }
  ]
}
```

## Settings (user customisation, no code)

Declare options in `plugin.json`; Nook renders the form (notch header **sliders** button, and Settings → Tabs & plugins).
Values are saved per plugin and pushed to the plugin live.

| `type` | Control | Extra fields |
|---|---|---|
| `toggle` | switch | — |
| `text` / `secret` / `textarea` | text box / hidden text / multi-line | — |
| `number` | slider if `min`+`max`, else a number box | `min`, `max`, `step` |
| `select` | dropdown | `options: ["a", "b"]` |
| `color` | colour well → `"#rrggbb"` | — |

Every entry: `key`, `label`, `type`, optional `default` and `help` (one muted line under the control).

```js
let settings = await nook.settings.get();          // defaults merged with what the user saved
nook.on('settings', (s) => { settings = s; apply(); });   // fires as the user edits — apply live, no reload
nook.settings.set('showStats', false);             // rarely needed; the form does this
nook.settings.open();                              // open this plugin's form in the notch
```

Saved values live in `~/Library/Application Support/Nook/Data/<id>.settings.json`.

**Code-level customisation:** the same form has **Edit code…** — for a built-in plugin it copies the folder to your
Plugins folder (your copy wins) and reveals it; **Revert to built-in** trashes your copy. CLI equivalent: `nook eject <id>`.

## Runtime

- Rendered in a transparent WKWebView inside the open notch. Content area ≈ **650 × height** points.
- `body` background must stay transparent; the notch behind is black.
- Injected CSS variables: `--fg #fff`, `--muted rgba(255,255,255,.55)`, `--card rgba(255,255,255,.06)`, `--card-hover rgba(255,255,255,.1)`,
  `--border rgba(255,255,255,.08)`, `--accent #ff9f0a`, `--good #30d158`, `--bad #ff453a`, `--radius 14px`. Font: `-apple-system`.
- No network CDNs; keep everything inline or in the folder. Use `nook.fetch` for HTTP (no CORS).
- Style: follow **docs/UI-GUIDELINES.md** (`nook guide`). The **Nook UI kit** (`nk-*` classes: cards, rows, buttons, pills, inputs, empty/error states…) is injected into every plugin — use it instead of writing your own.
- The webview stays alive while the app runs, so timers keep going between tab switches.

## Bridge — `window.nook` (all calls return Promises)

```js
nook.plugin                                   // { id, name }
nook.settings.get() / set(key, value) / open()  // user options declared in plugin.json (see Settings)
nook.storage.get(key) / set(key, value) / all()   // per-plugin JSON storage, survives restarts
nook.shell(command, { timeout })              // zsh -lc → { code, stdout, stderr }
nook.fetch(url, { method, headers, body })    // → { status, headers, body }  (body = text)
nook.system()                                 // → {
                                              //   cpu: { usage 0..1, cores },
                                              //   memory: { used, total }  (bytes),
                                              //   disk: { used, total, free } (bytes),
                                              //   network: { downBps, upBps },
                                              //   battery: { percent, charging, onAC, minutesLeft|null } | null,
                                              //   load: [1m, 5m, 15m], uptime (s), thermal: "nominal"|"fair"|"serious"|"critical" }
nook.clipboard.write(text) / read()
nook.open(url)                                // URL or file path
nook.notify(title, body)
nook.ai.chat(messages, { json, model, temperature })  // → assistant text via the user's Groq key (OpenAI-style messages);
                                              //   json:true = JSON mode. Default model openai/gpt-oss-120b. Rejects if no key.
nook.activity.set({ text, symbol, color })    // shows on the closed notch (color = css colour)
nook.activity.clear()
nook.notch.close()
nook.notch.pin(true|false)                    // keep the notch open when the mouse leaves
nook.notch.setHeight(px)                      // resize this tab's content area live
nook.on(event, cb)                            // 'open' | 'close' | 'show' (tab shown) | 'settings' | 'proxy' | 'dictation'
                                              // 'dragenter' | 'dragleave' | 'drop' (paths: real file/folder paths dropped on this tab)

nook.proxy.list()        // → { proxies: [{ id, name, scheme, host, port, hasAuth }], activeId|null }
nook.proxy.add(text)     // bulk: newlines/spaces/commas; host:port, host:port:user:pass, user:pass@host:port, scheme://…  → { added, bad }
nook.proxy.remove(id) / rename(id, name)
nook.proxy.connect(id) / disconnect()       // whole machine (system proxy via a local forwarder)
nook.proxy.ip()          // → { ip, city, country, countryCode, flag }   current public IP, through the proxy if on

nook.commands.list() / save(cmd) / remove(id) / run(id)   // AI Commands (Raycast-style): prompts with {selection} {clipboard} {app} {date} {time}
nook.commands.recordHotkey(id) / clearHotkey(id) / models() / lastRun()   // events: 'commands', 'commandRun'

nook.dictation.history() // → [{ id, date (ISO), status: 'done'|'failed'|'transcribing', text, raw, error, duration (s) }] newest first
nook.dictation.retry(id) / remove(id) / copy(id) / paste(id) / clear()
nook.dictation.state()   // → { recording, transcribing, holdShortcut: "⌃⌥", toggleShortcut: "⌥Space", hasKey }
nook.dictation.toggle()  // start/stop recording
```

Events carry the new state: `nook.on('proxy', s => …)` gets the same shape as `proxy.list()`; `'dictation'` gets `history()`.

## Agents (Codex sessions)

Agents use the installed Codex CLI and its existing login, configuration and tools. Manage them in Settings → Agents,
or create one with **+** in the bundled Agents tab. Full access is enabled by default: commands run without sandboxing
or approvals. Turn it off to use `workspace-write`; approval requests then fail instead of waiting for a terminal.

```js
await nook.agents.list()                    // → Agent[]
await nook.agents.save({ name, instructions, workingDirectory, model, effort, fullAccess, id }) // → saved Agent
// Omit id to create; defaults: workingDirectory "~", model "gpt-6.1-sol", effort "ultra", fullAccess true.
await nook.agents.remove(agentId)           // stops are required first; chats move to Trash
await nook.agents.models()                  // → [{ id, name }], ~/.codex/models_cache.json or fallback list
await nook.agents.sessions(agentId)         // → session summaries, newest first
await nook.agents.open(sessionId)           // → session including items
await nook.agents.send(agentId, null, text) // → new session; pass a sessionId to resume
await nook.agents.cancel(sessionId)         // terminate this turn's process tree
```

Agents have `{id, name, instructions, workingDirectory, model, effort, fullAccess}`. Effort levels are
`low/medium/high/xhigh/max/ultra`; availability depends on the model. Instructions are sent with Codex's
`developer_instructions` config on each turn. Prompts use stdin, never shell interpolation.

A session has `{id, agentId, title, codexSessionId, createdAt, updatedAt, status, revision, usage}` and, when opened,
`items`. Dates are Unix seconds. Status is `running/stopping/done/error/cancelled/interrupted` (`idle` before a turn).
One turn may run per chat; different chats may run concurrently. The local `id` is distinct from `codexSessionId`.

The **agents plugin** receives `nook.on('agents', agents)` when definitions change,
`nook.on('agentSession', ({session, item}) => …)` for streaming updates, and `agentStorageError` with an error string.
When `item` is present, `session` is a summary; upsert the item by `id`. Otherwise `session` includes the full transcript.
Discard updates older than the cached `revision`. Item IDs are scoped to a turn, since Codex reuses its wire IDs on resume.
Items preserve Codex's JSON fields (`agent_message`, `reasoning`, `command_execution`, `file_change`, `web_search`,
`mcp_tool_call`, `collab_tool_call`, `todo_list`, `error`), plus `user_message`. Command items include `command`,
`aggregated_output`, `exit_code`, `status`; tool arguments/results stay structured. Usage is Codex's latest turn usage.

Codex 0.163 emits item snapshots, not raw token deltas, and file changes contain paths/kinds rather than patch text.
File cards add a bounded **working-tree preview**, which can include pre-existing edits; new files show a bounded
content preview. A non-Git folder may have no diff. Session history lives in
`~/Library/Application Support/Nook/AgentSessions/<agentId>/<sessionId>.json`, definitions in `agents.json` (0600).
Codex also maintains its own session files. Removing an agent trashes Nook's history, leaving Codex's own history intact.

The bundled plugin pins after sending and unpins when leaving, changing chats/tabs or closing. Running chats continue
in the background and show the agent name with `sparkles` on the closed notch. Shortcuts: **⌘K** switch, **⌘N** new chat,
**Enter/⌘Enter** send, **Shift+Enter** newline, **Esc/⌘.** stop; Esc closes when idle. Tool cards support Tab and Enter/Space.

## Window management

```js
await nook.windows.state();       // {trusted, target: appName|null, busy, message, lastError,
                                  //  actions: [{id, title, group, shortcut, conflict}]}
await nook.windows.apply('nextDisplay'); // → updated state; rejects with a useful reason on failure
await nook.windows.openPrivacy(); // opens macOS Accessibility settings
await nook.windows.openSettings();// opens Nook Settings → Window Management
```

`apply` targets the exact focused window captured **before the notch opened**, even after the plugin gains keyboard
focus. Each notch keeps its own target, including pinned notches on separate displays. Opening that notch again captures
a new target; `state` never changes it. Accessibility permission is required.
Global shortcuts instead use the currently focused window, and are configured per action in native Settings (none assigned by default).

Action IDs: `previousDisplay`, `nextDisplay`, `previousDesktop`, `nextDesktop`; `leftHalf`, `rightHalf`, `topHalf`,
`bottomHalf`; `topLeftQuarter`, `topRightQuarter`, `bottomLeftQuarter`, `bottomRightQuarter`; `firstThird`, `centerThird`,
`lastThird`, `firstTwoThirds`, `lastTwoThirds`; `maximize`, `almostMaximize`, `maximizeHeight`, `maximizeWidth`, `center`, `restore`.
Display order is left-to-right, then top-to-bottom, and wraps. Relative size/position scale to the destination's usable area.
Almost Maximize defaults to 90% on each axis; native Settings adjusts it. Restore keeps the frame from before a series of
Nook layouts; a manual move starts a new series. History is in memory, bounded to 64 windows.

Desktop actions close all notches and follow the window to the adjacent desktop on its display. They require an accessible
title bar and enabled macOS Mission Control left/right Space shortcuts (custom key combinations are respected).
No desktop wrap, full-screen/Split View destinations, or All Desktops windows. See `docs/LIMITS.md` for compatibility limits.
`nook.on('windows', () => …)` signals shortcut edits and busy-state changes; call `state()` to reload your notch's state.
`nook.on('windowsError', message => …)` reports failures.
`lastError` retains the last failure until a successful action, including when a desktop move closed the panel.

## Developer tools

```bash
nook new <id> --name "My Thing" --symbol sparkles   # scaffold in your Plugins folder — live immediately
nook open <id>          # show it in the notch under the mouse   (also: toggle, close, reload, settings)
nook logs <id> -f       # console.log / console.error / uncaught errors from the plugin
nook validate <id>      # manifest, offline, transparent background, no edge stripes…
nook storage <id>       # what the plugin saved with nook.storage
nook eject <id>         # copy a bundled plugin into your folder to customise it
nook api | guide | limits
```

- CLI source: `cli/nook.ts` (Bun), linked at `~/.local/bin/nook`. Template: `cli/template/`.
- URL scheme: `nook://open/<id>`, `nook://toggle/<id>`, `nook://close`, `nook://reload`, `nook://settings`, `nook://check-updates`.
- Console output is written to `~/Library/Logs/Nook/plugins.log`. Web Inspector: Safari → Develop → this Mac → Nook.
- ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z work in plugin inputs (routed by the notch panel).
- What plugins can't do (and workarounds): **docs/LIMITS.md** (`nook limits`).

