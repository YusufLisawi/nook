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

## Keyboard and command palette

Open Nook from anywhere with **⌥⇧⌘Space** (General → Open Nook changes or disables it). Nook avoids
⌘Space (Spotlight) and ⌥⌘Space ([Finder search](https://support.apple.com/en-ie/guide/mac-help/mh26783/mac));
if the default conflicts with an enabled macOS symbolic shortcut, it tries ⌃⇧⌘Space, then ⌃⌥⇧⌘Space.
The notch under the pointer becomes key, focuses the current tab, and stays open during keyboard use.
Esc closes the palette first, then in-notch settings, then the notch, returning focus to the previous app.
**⌘1…⌘9** select tabs in dock order; **⌃Tab / ⌃⇧Tab** and **⌘] / ⌘[** cycle tabs. **⌘K** searches
tabs, enabled AI Commands and actions registered by loaded plugins on this display. ↑↓ select; Enter runs;
⌘Enter opens tab settings, edits AI Commands in Settings, or sends a plugin's alternate action.

```js
try {
  await nook.actions.register([
    { id: 'new-note', title: 'New note', subtitle: 'Create an empty note', shortcut: '⌘N' },
  ]);
} catch (error) { /* show an inline .nk-error */ }
nook.on('action', id => { if (id === 'new-note') createNote(); });
nook.on('actionAlternate', id => { /* optional ⌘Enter behavior */ });
```

`register` replaces this plugin's action list for this display; `register([])` clears it. Actions are removed on
plugin reload or when the display's host is destroyed. Register again after loading. Each call allows up to
100 actions with unique nonempty ids (≤128 characters) and titles (≤160); optional subtitles and shortcuts
are capped at 240 and 40 characters. Disabled tabs' actions are hidden. Selecting an action opens its tab and
delivers the event after focus, so the action can move the caret. Registration is async and rejects invalid data.
`shortcut` also binds a **local** shortcut while that plugin is selected. Use symbols (`⌘F`) or names
(`Cmd+Shift+F`); include Command, Control or Option. Keys are matched against macOS's characters ignoring
modifiers (`Space` and `Enter` are supported). Nook's navigation shortcuts take precedence; no global plugin
shortcut is installed. Other apps' private shortcuts cannot be detected automatically.

The injected UI kit includes visible focus rings, Tab navigation through usable controls, and a roving helper:

```html
<div class="nk-roving" data-nk-orientation="horizontal" aria-label="Commands">
  <button data-nk-item="run">Run</button>
  <button data-nk-item="edit">Edit</button>
</div>
```

Use stable `data-nk-item` values so focus survives row updates. ↑↓ navigate by default; horizontal groups use
←→. Home/End jump to the ends; navigation wraps and skips hidden/disabled items. One item per group is a Tab
stop; nested buttons and inputs remain reachable. Enter clicks the item; ⌘Enter dispatches a bubbling
`nk:alt` event on it. Handle that event for a row's alternate action. Inputs, editors, select controls and
sliders retain their own arrows/Enter. Mark a preferred initial control `data-nk-autofocus`, or call
`nook.keyboard.focus()` to request the first available control (including content that loads asynchronously).
The host requests this on keyboard entry and tab changes; plugins need no focus timer.

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

