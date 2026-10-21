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
- Web views are created on first display. Hidden views unload after a 15-second save grace period; disabling a feature unloads its views immediately. Persist drafts with `nook.storage` and restore them on load. Native timers and agent runs remain owned by their enabled native features.

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
nook.on(event, cb)                            // 'open' | 'close' | 'show' (tab shown) | 'settings' | 'proxy' | 'dictation' | 'mouse'
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

// Mouse now runs entirely in a Store helper (API v2).
nook.native.call('mouse.state', {args: []})
nook.native.call('mouse.set', {args: [{smoothness: 'high'}]})
nook.native.on('mouse', state => { /* refresh controls */ })
```

Events carry the new state: `nook.on('proxy', s => …)` gets the same shape as `proxy.list()`; `'dictation'` gets `history()`. Mouse helper notices use `nook.native.on('mouse', cb)`; refresh with `nook.native.call('mouse.state', {args:[]})`.

## Mouse controls — Store helper

Mouse is an API v2 Store plugin under `store/plugins/mouse`, with its event-tap implementation in a separate
universal helper. There is no in-app Mouse service or bundled Mouse tab. Build/install the Store package (or use
`nook dev` with the built folder), approve its Accessibility/background declaration, then turn on its own Enable
switch. Its controls send `nook.native.call('mouse.<method>', {args:[...]})`; events use `nook.native.on('mouse')`.
Methods retain `state`, `set`, `setButton`, `removeButton`, `learn`, `openPrivacy`. Configuration retains smoothing,
speed/acceleration, reverse/chatter, modifier choices and extra-button click/hold/drag mappings. State includes
`config`, `trusted`, `running`, `learning`, `error`, `actions`.
It is off by default. `set({enabled:true})` and `learn(true)` can request Accessibility; other edits do not prompt.
The state result’s `error` reports event-tap failures. While enabled or learning, permission/tap availability is checked every
two seconds and retried automatically. `mouse` notices cover startup, failure, recovery and learning; reload state
after a notice. Each mutation returns the updated state. No native Settings pane is added.

Rapid wheel reversals are preserved by default. `set({filterChatter:true})` opts into discarding opposite-direction
ticks arriving within 100 ms of the last accepted tick; enable it only for a wheel that bounces. Disabling or ending
learning stops new interception immediately and drains every suppressed button's release before removing the tap.
Overlapping gestures cancel the prior action while retaining its release. Generated shortcuts bypass Nook's global
and local shortcut routing. Scroll animation alone suppresses App Nap; an idle enabled tap does not.

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

## File Search, Clips and Windows — Store helpers

Install `file-search`, `clips`, `windows` or `launcher` in Settings → Plugin Store, then explicitly enable it in
Tabs & Plugins and approve its declared permissions. All four have `default: false` in the catalog and start
disabled. There are no built-in feature services or `nook.files.search`, `nook.clips.*`, `nook.windows.apply` bridges.
The v2 host still exposes scoped `nook.files.read/write/open/reveal/trash` and `nook.windows.frontmost`.

A package's web UI calls its own helper, using the existing transport:

```js
await nook.native.call('files.search', {args: ['report added:week !draft',
  {clientID: 'view-1', requestID: '1', scope: 'home', kind: 'all', limit: 60}]}); // file-search only
nook.native.on('files', update => { /* accept only this client and its latest request */ });
await nook.native.call('clips.historyPage', {args: ['text:invoice', {offset: 0}]}); // {items,next}
await nook.native.call('windows.apply', {args: ['leftHalf']}); // uses this notch's captured window
```

These are **package-local RPC methods**, not shared host APIs or calls to another plugin. Each package is
self-contained; disable/revoke stops its supervised helper and removes shortcuts/providers. See package tests.

- **File Search:** packed C matcher, Swift index/FSEvents, Spotlight fallback, previews/Quick Look and all actions
  run in `file-search`. Scope/kind filters, AND/OR, `!exclude`, phrases, wildcards, `ext:`, `kind:`, `size:`,
  `dm:` and `added:` remain supported. Stable `clientID`/`requestID` reject stale or other-display updates.
  `files.cancel/keepAlive/status/rebuild/preview/open/reveal/quickLook/copyPath/copyName/copyFile/openWith/trash`
  keep their former argument shapes inside `native.call(...,{args:[...]})`. Trash needs `{confirm:true}`.
  Settings uses the generic plugin form. Choose protected folder roots in Permissions & Trust; old app grants
  do not silently authorize a new helper. Startup gates protected/cloud/media/mounted paths before traversal.
  The optional search-mode file provider shares this same index; no duplicate index exists in Launcher or core.
- **Clips:** privacy markers/ignored apps, 2-second clipboard polling, private images, retention, screenshot-folder
  watcher and local Vision OCR run in `clips`. `historyPage/screenshotsPage` return `{items,next}` with an integer
  cursor or null; pages stay below the 1 MiB RPC limit. UI snippets are bounded (16,000 characters, 32 file paths);
  full text/path lists stay in saved history and native Copy/Paste. `history/screenshots/status/thumbnail/copy/paste/
  open/reveal/delete/pin/unpin/clear/quickLook` remain helper methods. Confirm deletes: file-reference and capture
  deletion trashes originals; retention/clear only trash owned image copies. `nook.native.on('clips', refresh)`
  invalidates results. Approve the screenshot folder before indexing it. This indexes existing captures, not screen
  recording. Rich paste needs Accessibility and restores/refuses the remembered external app.
- **Windows:** AX geometry/history and desktop/display moves run in `windows`. The host sends approved
  Accessibility+Windows helpers a `beforeOpen` event with `{context,pid?,windowNumber?}` before taking focus.
  Native RPC automatically carries a reserved `__context` for the originating notch. The helper resolves the
  exact captured window; absent/closed/unsupported targets refuse to move. It never retargets on a state request.
  Layout/desktop shortcuts use host v2 `hotkeys.register`, including native conflict checking and disable cleanup.
  Each is a native shortcut recorder in the plugin's grouped Settings pane. Graceful termination releases a held
  desktop drag before exiting. macOS/app Space and Accessibility limitations still apply.

First enable copies old clip history/images, index caches, window shortcuts and launcher history/preferences
into `NOOK_DATA_DIR`; old files/defaults are read-only. Repeated migration preserves subsequent plugin edits.
File cache scope/fingerprint changes intentionally force a safe rebuild. Never remove legacy user data with unlink.

## Keyboard and command palette

Open Nook from anywhere with **⌥⇧⌘Space** (General → Open Nook changes or disables it). Nook avoids
⌘Space (Spotlight) and ⌥⌘Space ([Finder search](https://support.apple.com/en-ie/guide/mac-help/mh26783/mac));
if the default conflicts with an enabled macOS symbolic shortcut, it tries ⌃⇧⌘Space, then ⌃⌥⇧⌘Space.
The notch under the pointer becomes key, focuses the current tab, and stays open during keyboard use.
Esc closes the palette first, then in-notch settings, then the notch, returning focus to the previous app.
**⌘1…⌘9** select dock items (a group counts once); **⌃Tab / ⌃⇧Tab** and **⌘] / ⌘[** cycle dock items. **⌥⌘← / ⌥⌘→** cycle deck members. **⌘K** searches
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

## Community Plugin Store

Settings → **Plugin Store** browses `YusufLisawi/nook-plugins` on GitHub. Search by name, author, or tag; select a plugin for its source, description, screenshots, version, and install/update/uninstall actions. **Share** copies `nook://install/<id>`, which opens details and waits for an explicit Install click. No new web bridge namespace is required.

```sh
nook search writing [--json]
nook install word-count
nook update [id]                  # one or all Store-managed plugins
nook uninstall word-count         # Trash; saved data/settings are retained
nook publish ./my-plugin          # validation + preview; makes no remote changes
nook publish ./my-plugin --yes    # authenticated gh: fork, contribution branch, PR
```

The public repository's complete initial contents live in this source tree's `store/` folder. Each `plugins/<id>/` contains a valid Nook plugin and `store.json` with `description`, `author`, semantic `version`, `tags: []`, and `screenshots: []` (local relative image paths). `node scripts/validate.mjs` checks every package; `node scripts/generate-index.mjs` generates the catalog. CI validates PRs and regenerates the index on `main`.

The app and CLI cache `index.json` under `~/Library/Caches/com.yusuf.nook/PluginStore/`. A missing repository displays an empty Store; unavailable networking falls back to saved entries. Installation uses immutable Git trees and verifies blob/tree hashes before moving a staged package into the user Plugins folder. Files use the raw CDN only when their hashes match, with immutable Git blobs as a fallback, so current packages usually need just one GitHub API request. `.nook-store.json` records the installed version and tree SHA. Updates refuse to overwrite unrelated or edited copies, and move replaced copies to Trash. Packages allow regular files, with executable helpers under `bin/` (200 files, 5 MB each, 20 MB total); no hidden files, symlinks, or unsafe paths. Public GitHub API rate limits can delay downloads. Plugins can run commands as the user, so review source before installing.


## Native Settings and shortcuts

Settings → **Tabs & Plugins** shows each tab’s height, shortcut, manifest options, and Edit Code / Revert controls inline.
Drag dock items or expanded group members to reorder them; row menus also offer Move Up / Move Down. **Keyboard Shortcuts** collects
tab, AI command, dictation, and native extension assignments and identifies duplicate key combinations.

Native features can add searchable panes and expose existing shortcut storage without editing Settings switches:

```swift
SettingsRegistry.register(id: "windows", title: "Window Management", symbol: "macwindow",
                          tint: .teal, order: 35, keywords: ["move", "resize", "snap"]) {
    WindowsPane() // a native grouped Form
}
ShortcutRegistry.register(id: "windows.center", title: "Center Window", group: "Window Management",
                          get: { WindowShortcuts.center },
                          set: { WindowShortcuts.center = $0 })
```

Register on the main thread during service startup. Pane and shortcut ids must be stable and unique; registering the
same id replaces it. `keywords` and shortcut `group` are optional. Shortcut accessors use `TabHotkey?`; `nil` clears
an assignment. The feature still owns persistence and execution. Registration adds native Settings controls;
it does not grant web plugins new key-tap access or add a JavaScript bridge API.

The sidebar searches pane titles and setting keywords. Settings remembers the selected pane and window frame,
and `nook://settings/shortcuts` / `nook://settings/about` open the new built-in panes.

Settings pre-warms its window and caches background discovery for Codex, command-line tools, login items, and
microphones. Status refreshes when returning to Nook; ChatGPT & Codex and Command Line also have **Refresh Status**.
Plugin reloads, editable-copy creation, and reverting to the Trash run in the background with inline progress/errors.
Plugin options apply immediately to the running plugin. Settings and command JSON writes coalesce for up to 150 ms
on a utility queue and flush when Nook quits normally. Use the Settings UI or bridge to edit options; direct edits
to cached settings/secret files are read on the next app launch.

## Cleaner — `nook.cleaner`

```js
await nook.cleaner.clean('caches', 60); // → { bytes, moved, skipped, protectedCount, failed }
```

Moves eligible immediate children to the system Trash with `FileManager.trashItem`, without listing `~/.Trash`.
Categories are fixed: `caches`, `logs`, `derived`, `devices`, `simulators`, `packages`, `downloads`.
The optional days argument (default 60, clamped to 7–365) applies only to Downloads: regular files older than
that modification age, never folders. No arbitrary paths; symlink roots/components and immediate symlink items
are skipped. Apple and package caches are excluded from `caches`. Calls run serially off the main thread.
`bytes` estimates allocated bytes moved. Protected/unreadable candidates stay in place and increment `skipped`
and `protectedCount`; other move failures increment `failed`. A directory with an unreadable descendant is one
skipped candidate and stays intact. The bundled Cleaner displays partial results and a single Full Disk Access hint.
Trash size is unknown; confirmed emptying uses Finder AppleScript via `nook.shell` and may request Automation
permission to control Finder. Finder empties all Trash, including mounted volumes. Homebrew keeps its own
confirmed `brew cleanup -s` operation. Neither action is part of this bridge API.

## Dock visibility and tab groups

Settings → **Tabs & Plugins** separates **Enable plugin** from **Hide from dock**. Hidden plugins remain enabled:
existing `nook://open/<id>` / `toggle`, tab hotkeys, AI/agent opens, and ⌘K still use the same plugin ID. Hiding
only removes a plugin from the dock and numbered/cycling destinations; it does not stop an already-loaded web view.

**New Group…** creates a named SF Symbol deck with at least two plugins and an optional global shortcut. A plugin
belongs to one group. The group occupies one dock position; member shortcuts open that member in its deck. The group
shortcut toggles the deck on its last enabled member. A small pill row selects members; **⌥⌘← / ⌥⌘→** and horizontal
swipes move inside the deck. **⌘1…9**, **⌃Tab / ⌃⇧Tab**, and **⌘[ / ⌘]** address dock items, counting a group once.
Hidden/disabled members are skipped by dock/deck cycling; directly opening a hidden member still shows its selected
pill. Numbered/dock entry falls back to a visible member if the remembered member is hidden. An all-hidden group has
no dock icon. Deleting a group returns its members with their existing enabled/hidden preferences.

Drag dock items in Settings or the notch, expand a group to reorder members, or use each row's Move Up / Move Down
menu. Right-click a dock icon for Hide from Dock, Add to Group, and Settings. Existing plugin APIs and active plugin
IDs are unchanged; there is no new JavaScript namespace. Presentation preferences are `hiddenTabs` (string array),
`tabGroups` (JSON Data containing stable IDs, name, symbol, ordered members, optional `TabHotkey`, and last member),
and `dockItemOrder` (string array of plugin IDs and `group:<UUID>` IDs). `disabledTabs` remains independent.

Keyboard Shortcuts now includes Open Nook, all Window Management actions, tab groups, and the fixed navigation
bindings alongside tabs, AI Commands, and dictation. General and Window Management use the same conflict-aware
recorder. `ShortcutRegistry.register` also accepts optional `defaultShortcut: TabHotkey?` and `editable: Bool`
(default true); fixed navigation entries are read-only and participate in conflict checks. Known macOS symbolic
shortcuts are checked; other apps' private shortcuts remain undiscoverable. Window shortcuts invoked inside the
notch use that display's captured external window.

## Native search mode and Store Launcher

The small native SwiftUI search surface stays in core to own notch geometry, text focus, keyboard routing and
presentation of value-only results. The `launcher` Store helper owns app discovery, ranking/frecency/history,
system commands, Quick AI orchestration and every smart-answer provider. `file-search` independently contributes
files from its existing helper. No app index, answer math/unit/currency/time/color/base/percent implementation or
`places.tsv` is compiled/bundled in Nook. Additional answer providers remain one new Swift file subclassing
`LauncherAnswerModule` + conforming to `LauncherAnswerProvider` in `store/plugins/launcher/native/`; Objective-C
class discovery registers them without editing a switch. Build the helper with `bash .../build.sh`.

### Generic search contributions (API v2, `launcher` permission)

```json
{"contributes":{"searchProviders":[{"id":"search","method":"search.query","actionMethod":"search.activate"}]}}
```

Requires a native helper and declared/approved `launcher`. The host queries up to 16 enabled providers with
`{query,items}`; `items` is the bounded existing Nook action/tab catalog, which a provider may rank alongside its
own items. Reply `{items:[{id,title,subtitle?,symbol?,kind?,confirm?,keyEquivalent?}],answer?}`. IDs are local to that provider.
`keyEquivalent:"tab"` opts one result into Tab activation while searching.
Results are generation-checked, capped at 100/provider; only one in-flight request plus the newest replacement
exists per provider/display. Closing/disable discards queued work. Provider order is stable; arrival is asynchronous.

`answer` is a plain value: `{section,expression,leftBadge,result,rightBadge,copyValue,isAvailable?,note?,
copyWithUnits?,swatch?:{red,green,blue}}`. Existing prefix `answerProviders` still use their bounded async cache.
`nook.native.on('searchChanged',...)` / helper notification `searchChanged` invalidates a visible search.
The host listens to those notifications directly; a background helper needs no web page for search.

Activation calls `actionMethod` with `{id,alternate,confirmed}`. `confirm:true` requests a second explicit activation.
The helper may reply `{answer}` (e.g. Quick AI) or `{hostItemID}` to run an item from the supplied Nook catalog;
the host checks that the ID is still present. Copy/Paste go through that provider's clipboard/Accessibility grants.
`host.launcher.open {}` opens native search mode on the relevant display. The Launcher plugin's Open shortcut
uses this API through the host's hotkey registration. Search mode is unavailable until Launcher is installed/enabled.
System Empty Trash and Sleep require confirmation; Empty Trash keeps Finder's explicit destructive semantics.

### Native shortcut settings

A v2 setting can use `"type":"shortcut"`, `"default":""` for unassigned, or a JSON-encoded
`{keyCode,modifiers,display}` string. Declare `hotkeys` permission. Nook renders the standard native recorder;
users never edit JSON. Use keys `shortcut.<hotkey-id>` so the recorder and host registration share conflict identity.
The helper receives the string through settings and registers/unregisters it with `host.hotkeys.*`.

## API v2

`apiVersion: 2` opts into permission checks and separate native helper processes. Omitting it keeps the
existing v1 web format working during migration. V2 never loads plugin native code into Nook.

```json
{
  "id": "example", "name": "Example", "apiVersion": 2,
  "version": "1.0.0", "symbol": "puzzlepiece.extension", "entry": "index.html",
  "permissions": ["clipboard"],
  "native": {
    "command": "bin/helper", "background": true,
    "permissions": ["background", "accessibility"]
  },
  "contributes": {
    "launcherItems": [], "answerProviders": [], "hotkeys": [], "settings": [],
    "menuBar": [], "notchActivity": [], "urlHandlers": [], "backgroundJobs": []
  }
}
```

`native` and `contributes` are optional. Web-only v2 plugins put permissions at the top level. Native and
top-level permissions are combined. Use either `command` (a relative executable inside the plugin),
`run: ["node", "helper.mjs"]`, or `command: {"run": ["python3", "helper.py"]}`. Interpreters supported by
phase 1 are node, python3, ruby, swift, bash and sh; the second argument must be a relative script, never an
interpreter switch. Interpreter availability is checked when running/validating, not while installing.
For `bin/helper`, Nook prefers `bin/arm64/helper` or `bin/x86_64/helper`, then a universal `bin/helper`.
No build script is executed at installation: ship compiled helpers, use an interpreter, or build locally.

`background: true` requires `background` permission and runs while the plugin is enabled. Otherwise the
helper runs only while its tab is open on at least one display. Disable/revoke/uninstall stops its process
and contributions. Helpers must exit on stdin EOF and handle SIGTERM; after two seconds Nook escalates to
SIGKILL. An internal CLI exec trampoline gives production helpers a separate process group, so ordinary
child processes are stopped too. Deliberately daemonized, unsandboxed processes are outside this guarantee.
A crash fails outstanding requests and retries after 1, 2, 4, 8, 16, 32, then 60 seconds; 60 seconds of healthy
uptime resets backoff. UI reloads/file edits restart helpers. Helpers are never launched by `nook validate`.

### One host surface, two transports

In web JavaScript call `await nook.host.call(method, params)` (or new v2 conveniences such as `nook.ai.complete(params)`, `nook.files.read(params)` and `nook.hotkeys.register(params)`); in the helper send a JSON-RPC request named
`host.<method>` with the **same params object and result**. Existing web conveniences such as
`nook.clipboard.read/write`, `nook.storage.*`, `nook.settings.*`, `nook.shell`, `nook.fetch`, `nook.notify`,
`nook.activity.*` and `nook.notch.*` pass through the v2 permission gate too. Old feature-specific namespaces
(`mouse`, `audio`, `proxy`, `commands`, etc.) are v1 APIs; v2 feature behavior belongs in helpers.

| Method | Params / result | Permission |
|---|---|---|
| `notch.open`, `notch.close` | `{}`; open this plugin on the current display | approval only |
| `notch.pin`, `notch.togglePin` | `{enabled: boolean}` / `{}` | approval only |
| `notch.setHeight` | `{height: number}`; clamped 80–400 | approval only |
| `activity.set` / `notch.activity`, `activity.clear` | `{text,symbol?,color?}` / `{}` | approval only |
| `storage.get`, `storage.set`, `storage.all` | `{key}`, `{key,value}`, `{}`; per-plugin JSON | approval only |
| `features.list` | `{}` → `[{id,title,enabled}]`; effective shared feature state | approval only |
| `settings.get`, `settings.set`, `settings.open` | `{}`, `{key,value}`, `{}`; declared options only | approval only |
| `clipboard.read`, `clipboard.write`, `clipboard.watch` | `{}`, `{text}`, `{enabled}`; `clipboard` events each changed sample (1 s) | clipboard |
| `files.read`, `files.write` | `{path}` → UTF-8 text; `{path,text}` (4 MB limit) | files |
| `files.open`, `files.reveal`, `files.trash` | `{path}`; Trash semantics | files |
| `fetch` / `network.fetch` | `{url,options?:{method,headers,body}}` → `{status,headers,body}`; HTTP(S) | network |
| `network.open` | `{url}`; HTTP(S)/mailto, opens the default app | network |
| `shell` | `{command,options?:{timeout}}` → `{code,stdout,stderr}`; timeout 1–120 s | shell |
| `notifications.post` / `notify` | `{title,body}`; macOS notification consent still applies | notifications |
| `ai.complete` | `{prompt,provider?:"codex"|"groq"|"openai",model?,effort?}` → text via AIBrain | ai |
| `selection.get`, `selection.paste` | `{}` → selected text; `{text,keepOnClipboard?}` | accessibility |
| `windows.frontmost` | `{}` → `{name,bundleID,pid,accessibility,title?,frame?}`; title when AX trusted | windows |
| `accessibility.perform` | `{action:"press"|"raise"|"increment"|"decrement"|"confirm"|"cancel"}` on focused element | accessibility |
| `secrets.get`, `secrets.set`, `secrets.remove` | `{key}`, `{key,value}`, `{key}`; per-plugin Keychain service, never host AI keys | secrets |
| `hotkeys.register`, `hotkeys.unregister` | `{id,keyCode,modifiers,title?,display?}`, `{id}`; CGEventFlags, emits `hotkey` | hotkeys |
| `launcher.items` / `actions.register` | `{items:[{id,title,subtitle?,shortcut?}]}`; emits `action` / `actionAlternate` | launcher |
| `launcher.answers` | `{id,prefix,method}`; helper query params `{query}` → `{result,copyValue?,section?}` | launcher |
| `jobs.register`, `jobs.unregister` | `{id,interval}` (1–86400 s), `{id}`; emits `job` | background |
| `log` | `{level,message}` → `nook logs <id>` | approval only |

File paths may be relative to `NOOK_DATA_DIR` or absolute inside a folder chosen during consent. Both lexical
scope and resolved ancestors are checked, including nonexistent write targets. This is a host API boundary,
not a filesystem sandbox: trusted native helpers and shell commands run as the user. Concurrent external
symlink replacement remains a limitation; use helpers/security-scoped file APIs for adversarial file trees.
Selection uses AI Commands' SelectionGrabber, including its clipboard and select-all fallback. Only request
selection/paste after an explicit user action. When approved Accessibility plugins are enabled, the host captures
the external text target before the notch opens; fallback/paste closes the notch, restores it, and refuses a
changed/unavailable target. Helpers calling while closed use the current external target. Generic AX actions use the
currently focused element; exact captured-window layouts remain in the existing Windows feature until migration.
`ai.complete` defaults to Codex/gpt-6-luna/medium; supply a matching model when selecting Groq/OpenAI.

### Helper protocol and web messaging

Stdin and stdout carry **newline-delimited UTF-8 JSON-RPC 2.0** objects, one per LF; CRLF and empty lines are
accepted. This is not LSP Content-Length framing. Embedded newlines must be JSON escaped. Each frame is at
most 1 MiB, there are at most 128 pending requests in each direction, and web-to-helper calls time out after
15 seconds. Keep stdout exclusively for protocol messages; stderr is bounded into the plugin log. IDs may
be strings or numbers; responses must carry exactly one of `result` or `error`. Nook uses string request IDs.

```js
// Web → helper method; params must be a JSON object or array.
const value = await nook.native.call('hello', {name: 'Nook'});
// Helper notifications, scoped to this plugin on all displays.
nook.native.on('progress', data => { /* update UI */ });
nook.native.on('ready', () => { /* helper started/restarted; refresh state */ });
```

```json
{"jsonrpc":"2.0","id":"ui-1","method":"hello","params":{"name":"Nook"}}
{"jsonrpc":"2.0","id":"ui-1","result":{"message":"Hello, Nook!"}}
{"jsonrpc":"2.0","method":"progress","params":{"percent":50}}
{"jsonrpc":"2.0","id":7,"method":"host.clipboard.read","params":{}}
{"jsonrpc":"2.0","id":7,"result":"clipboard text"}
{"jsonrpc":"2.0","id":8,"error":{"code":-32001,"message":"Permission denied: clipboard."}}
```

Nook sends `host.ready` with `{apiVersion:2,pluginID}` after spawning, and `host.event` with `{event,data}` for
settings, clipboard, hotkey, action, job, menuBar and URL events. A notification has no `id` and gets no response.
Respond to every request, correlate responses by ID, ignore unknown notifications, and handle host errors.
Do not synchronously block a request handler waiting for the host: continue reading both directions.
The helper gets `NOOK_PLUGIN_ID`, `NOOK_PLUGIN_DIR`, `NOOK_DATA_DIR`, a standard PATH and basic user/locale
variables. Nook does not forward arbitrary injected environment variables or AI credentials. Save data only
in `NOOK_DATA_DIR`; it survives package replacement and uninstall. Never daemonize the helper.

### Contributions

Every `contributes` value is an array, up to 100 entries, with unique `id`s. All registrations are removed on
disable/revoke/uninstall. Declarative hotkeys/items/jobs match the parameter shapes above. `answerProviders`
uses `{id,prefix,method}`; the native launcher reads a bounded cache, asks the helper asynchronously, shows a
loading/error result, and never blocks its 2 ms native answer budget. Prefixes should be specific. Entries and
answers require Launcher enabled, and answers also require Smart Answers. Keyboard & Open Nook may be off.
The generic native search renderer consumes these prefix providers alongside Store searchProviders.
`settings` entries `{id,title?}` add grouped native Settings panes using the plugin's top-level `settings` schema.
`menuBar` entries `{id,title?,symbol?}` create an SF Symbol status item and emit `menuBar: {id}` on activation.
`urlHandlers` entries `{id}` accept `nook://plugin/<plugin-id>/<handler-id>?...`, emitting `{handler,url}`.
`notchActivity` reserves named activities; plugins publish/clear active text through `activity.set/clear`.

### Permissions, trust and Store updates

Declarations are not grants. A native consent sheet lists permissions in plain words before a v2 Store
install/update or first enable. Developer copies are marked **Developer**. Use Settings → Tabs & Plugins →
Permissions & Trust to review/revoke; revocation disables the plugin and immediately stops helper resources. Unknown host methods
and undeclared permissions reject. Available permissions are `files`, `clipboard`, `accessibility`, `microphone`,
`network`, `shell`, `ai`, `background`, `hotkeys`, `notifications`, `launcher`, `windows`, `secrets`.

**Helpers are unsandboxed child processes, not a security boundary.** They can access files/network directly
and may use Nook's effective TCC grants. TCC attributes requests to responsible code, so launched-via-Nook
and launched-via-Terminal/Xcode can behave differently. An update/signing identity change or particular
service may require a helper-specific grant. The consent sheet explicitly says this. Check in a signed build
on a clean macOS profile before distributing Accessibility/microphone plugins; do not modify TCC databases.
See [Apple DTS on responsible code and file permissions](https://developer.apple.com/forums/thread/678819).

The Store index adds `default: true` and `sha256`. On the first successful online bootstrap Nook installs
missing defaults; failures retry at a later check and never remove bundled or installed plugins. Nook checks
daily and on Settings open (30-second debounce) while the Plugin Store feature is on. Turning it off cancels
Store networking and its update timer. Preinstall does not enable a default-off feature: Mouse appears as
`plugin:mouse` in the shared Features registry and starts only after its existing switch is enabled and trust is approved.
Unchanged permission/trust grants update silently; added
permissions or a newly introduced helper require consent before the app replaces the old package. CLI
installs/updates verify packages; the running host requests approval before executing newly granted capabilities.
Offline, existing packages and bundled v1 plugins continue working.

The Store keeps its immutable Git tree/blob checks and adds a canonical SHA-256 for **all** package files:
UTF-8 path, NUL, Git mode (`100644` or `100755`), NUL, decimal byte count, NUL, raw bytes, repeated in UTF-8
path order. The receipt itself is excluded. V2 Store installs require SHA-256. Only regular files are packaged;
executable files must be under `bin/`. No symlinks, hidden files, traversal, CDNs or automatic install scripts.
Limits remain 200 files, 5 MB/file, 20 MB/package. Hashes prove integrity relative to the catalog, not author identity
or safety; review the source and helper binary provenance. Updates preserve local edits and Trash the old copy.

### Developing and publishing

`nook new <id> --native swift|rust|node|python [--output <parent>]` creates a working hello helper and UI.
Swift/Rust scaffolds need `bash build.sh` first; Node/Python need the named runtime installed. Rust uses
serde_json rather than an unsafe handwritten JSON parser; Nook gains no app dependency. Templates are in
`store/templates/`. `nook validate <folder>` validates v2 paths, permissions and helper availability without
executing code. `nook dev <path>` mirrors into the watched plugin folder and follows edits, including helper
binaries. It never launches Nook or executes a build script; use an already running app and approve Developer
access. Stop dev before changing the plugin id. `--once` performs one safe sync. Existing unrelated plugins
or edits to the mirror are preserved/refused. `NOOK_SUPPORT_DIR` isolates CLI new/dev operations in tests.

Use `nook logs <id>` for web/helper diagnostics. Test JS with a mocked `window.nook` and test RPC with pipes
and an isolated `NOOK_DATA_DIR`. Build helper code before validating/publishing. Add `store.json`, increment
both versions, run Store validation/index generation, review `nook publish <path>`'s preview, and submit through
the Store PR workflow. Source review, deterministic binaries, signing/notarization and any runtime dependencies
belong in the plugin's documentation. The full build guide ships as `store/SKILL.md` and in `skill/nook/plugin-v2.md`.

V2 host shell commands belong to their plugin: stdout/stderr drain concurrently (1 MiB captured each),
timeouts stop the process group, and disabling/revoking cancels them. In-flight HTTP and AI tasks are cancelled too. V2 page resources are released when the last visible page
unloads, except resources owned by an enabled background helper. A second visible display keeps them alive.


## Feature availability and page lifetime

Settings → Features controls native service lifetimes and reuses the existing disabled-tab preference.
Disabled features reject bridge calls without creating their services; extension namespaces are registered only while
needed. Shortcuts keep their saved assignments but do not route while their owner is off.

```js
const features = await nook.features.list(); // [{ id, title, enabled }] — effective state, including dependencies
nook.on('features', rows => { /* hide controls for disabled capabilities */ });
nook.on('visibility', visible => { /* start/stop page polling immediately */ });
```

`open`/`show` still carry the selected tab ID; `close` means the notch closed. Stop page timers on hide/close and restart
on show. A loaded page receives `visibility` when its host changes visibility. Pages load only when shown, so initialize
as visible. Unopened tabs create no web view. A disabled tab unloads immediately; a hidden tab unloads after 15 seconds.
Unloading cancels that page's pending shell, HTTP and `ai.chat` work and removes its action registrations. Long-lived
agent chats and native countdowns belong to their native services, not a page. Detached processes deliberately launched
outside the shell's process tree are outside page lifetime control.

Native feature IDs include `launcher`, `smartAnswers`, `launcherFiles`, `files`, `clipboard`, `screenshots`, `windows`,
`commands`, `agents`, `dictation`, `links`, `proxy`, `mixer`, `monitor`, `media`, `timers`, `keyboard`,
`teleprompter`, `cleaner`, `pluginStore`, `home`, `notes`, `scratch`, and `shelf`. Other discovered plugins use
`plugin:<id>`, including `plugin:mouse` for the migrated Mouse plugin. Features and Tabs & Plugins share
one enable state; revocation turns that same state off. Clipboard and screenshot history share the Clips tab; either can run independently. `system` calls require
Monitor and a visible calling tab. Home checks capabilities before invoking stats/timer APIs.

### Scoped folder metadata

`host.files.scopes {}` / `nook.host.call('files.scopes')` returns the plugin's approved folder paths (`files`
permission). Helpers can consult this before starting watchers or traversing protected paths. It does not add a
grant, request TCC, or sandbox native code. Change approval through Settings → Tabs & Plugins → Permissions & Trust.
