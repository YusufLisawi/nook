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

nook.mouse.state()       // → { config, trusted, running, learning, error: string|null, actions: [{ id, label }] }
                         //   config: { enabled, smoothness: off|low|regular|high, speed 0.3–3, acceleration 0–1, reverse, filterChatter (default false),
                         //             horizontalModifier|preciseModifier|quickModifier: none|shift|option|control|command,
                         //             buttons: { "<button number>": { click, hold, drag } } }   (2 = middle, 3 = back, 4 = forward…)
nook.mouse.set({ smoothness: "high" })       // merge top-level settings (not `buttons`: use setButton); each call returns the new state
nook.mouse.setButton("3", { click: "back" })   // click/hold = an action id, drag = "none" | "spaces"
nook.mouse.removeButton("3") / learn(true|false) / openPrivacy()   // learn: the next button pressed arrives as nook.on('mouse', { button })
                         // nook.on('mouse') also fires with { running: true } once the engine is up, and { learning: false } when learning ends
```

Events carry the new state: `nook.on('proxy', s => …)` gets the same shape as `proxy.list()`; `'dictation'` gets `history()`; `'mouse'` gets a small notice (see above), so call `nook.mouse.state()` to read the new state.

## Mouse controls — `nook.mouse`

The Mouse namespace is registered through `BridgeRegistry` at startup; its UI is a normal bundled web plugin.
It is off by default. `set({enabled:true})` and `learn(true)` can request Accessibility; other edits do not prompt.
`state().error` reports event-tap failures. While enabled or learning, permission/tap availability is checked every
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

## Clipboard and screen captures — `nook.clips`

```js
await nook.clips.history('text:invoice date:today'); // clipboard entries, pinned first, newest first
await nook.clips.screenshots('name:"Screen Shot"'); // screenshots AND recordings in the capture folder
await nook.clips.copy(id);                         // text, native image data, or file URLs
await nook.clips.paste(id);                        // close notches, activate previous app, send ⌘V (Accessibility required)
await nook.clips.open(id);                         // open a file or link
await nook.clips.reveal(id);                       // Finder, files only
await nook.clips.quickLook(id);                    // native Quick Look, files only
await nook.clips.delete(id);                       // move associated files to Trash, then remove the entry
await nook.clips.pin(id); await nook.clips.unpin(id);
await nook.clips.clear();                          // all clipboard entries, including pins; original files stay in place
await nook.clips.thumbnail(id);                    // small JPEG data URL, or null (Quick Look; load lazily)
await nook.clips.status();                         // enabled, ocr, indexing, folder, clipboardLoading,
                                                  // screenshotsLoading, clipboardError, screenshotsError
```

Filters are optional strings. Bare terms search name, plain/OCR text, source app, and paths. `name:`, `text:`,
and `date:` clauses are combined with AND; quote values with spaces. Dates accept `today`, `yesterday`,
or `YYYY-MM-DD` in the local time zone. Invalid dates match nothing.

Entries contain `{id, kind, name, text, paths, date, modifiedAt, source, pinned, hasFile, ocrText}`.
Dates are Unix milliseconds (`modifiedAt` is 0 when unavailable). Kinds: `text`, `link`, `image`, `files`,
`color`, `screenshot`, `recording`. Rich text is stored as plain text; native colors become hex strings.
Images/screenshots copy as TIFF image data; recordings copy as file URLs. Listen for `nook.on('clips', refresh)`
(invalidation event, empty object payload, sent to the bundled `clips` plugin). All calls return Promises and can reject.

Settings → Clipboard controls capture, age/capacity, ignored app names/bundle IDs (one per line), capture folder,
OCR, and clearing. Pins are exempt from clipboard retention/capacity. `delete` on a file-reference entry trashes
the **original referenced files**; confirm this in your UI. Retention and `clear` only trash Nook-owned image copies.
Screenshots stay in their original folder. History and the OCR index are local in `~/Library/Application Support/Nook/Clips/`.

## File Search (`nook.files`)

Native, in-memory filename search, shared by the Files tab and launcher. No shell or network dependency.

```js
const options = { clientID: 'my-view', requestID: '1', scope: 'home', kind: 'all', limit: 60 };
const initial = await nook.files.search('report added:week !draft', options);
nook.on('files', update => {
  // Accept only your clientID and latest requestID; events reach every screen of this plugin.
  // { clientID, requestID, query, scope, kind, results, gathering, indexing,
  //   source: 'index'|'spotlight', total?, truncated, elapsedMs, notice?, error? }
});
await nook.files.cancel('my-view');             // on close; frees this client's search cursor
await nook.files.keepAlive('my-view');          // every 30 s while visible; false means rerun
const preview = await nook.files.preview('/absolute/path');
// { path, name, kind, size, modified, text?, truncated?, thumbnail?, notice? }
// PNG data URL thumbnails; text reads at most 20 KB; timestamps are Unix seconds.
await nook.files.open(path);
await nook.files.reveal(path);
await nook.files.quickLook(path);              // same file toggles native Quick Look
await nook.files.copyPath(path);
await nook.files.copyName(path);
await nook.files.copyFile(path);               // file URL, pasteable in Finder
const apps = await nook.files.openWith(path);
await nook.files.openWith(path, apps[0].path);
await nook.files.trash(path, { confirm: true }); // caller MUST show explicit confirmation first
const status = await nook.files.status();      // { ready, count, notice }
await nook.files.rebuild();                    // background rebuild using current native Settings
```

`scope`: `home`, `Developer`, `Downloads`, or `all` (all folders configured in Settings → File Search).
Omit it to use the default scope. `kind`: `all`, `folder`, `app`, `document`, `image`, `pdf`, `code`, `video`,
`audio`, `archive`. `limit`: 1–100, default 60. A result is
`{ path, name, kind, category, size, modified, added, lastUsed }` (`added` falls back to filesystem creation).
Results rank exact basename, prefix, word start (including ASCII camel case), substring, then subsequence;
newly added/modified files and Nook-opened frecency order each tier. Empty searches show newest added/modified
files, including never-opened Downloads and screenshots when folder access permits. With `kind: 'all'`, Recent omits folders; choose the
Folder filter to see recent folders. Match tiers always dominate usage. Native results update each keystroke;
the bridge has no debounce. Queries retain all matching candidate IDs for safe incremental narrowing.

Query syntax (AND binds tighter than OR):

- `annual report` (AND), `report | invoice` (OR), `!draft` (exclude), `"annual report"` (phrase).
- `*.png` / `?` wildcards; `~/Desktop/ report` or a quoted absolute folder path for path scope.
- `ext:pdf;docx`; `kind:image|folder|app|doc|video|audio|code|archive` (any listed kind).
- `file:` / `folder:` (optionally followed by a name, such as `folder:Projects`).
- `size:>10mb` / `size:<1gb` (binary KB/MB/GB/TB); `dm:today`, `dm:week`, `dm:2026-10-21`;
  `added:today` / `added:week` / a calendar date. Today uses local midnight; week means the last seven days;
  a calendar date matches that local day. `!dm:today` and `!added:week` are supported; negated calendar dates
  produce an inline syntax error. Queries are limited to 2,048 UTF-8 bytes, 64 atoms and 32 extensions per filter.

The first reply is asynchronous; further `files` events replace it after index updates. Requests replace the
same client's previous search. Use a unique `clientID` per web view and new `requestID` per keystroke. A request
superseded before its first reply receives `cancelled: true`, so every bridge promise settles. Clients without
heartbeats expire after 120 seconds when refreshed; explicit cancellation releases them immediately.
`total` counts all matching names in the own index; `truncated` means more matches exist than displayed rows.
There is no 20,000-candidate cap in the own index. Bounded Spotlight candidates provide partial metadata
results during builds and for folders without direct access (`source: 'index+spotlight'` when merged).
Both sources use the same query compiler/ranking. macOS may withhold protected metadata until access is granted.
`gathering: false` means the current result calculation completed, while later file changes can still emit updates.

`filesSettings` fires when scope/hidden/exclusions change. Home is scanned in the background, excluding Library,
cache/dependency/build folders, hidden files and common app/package internals by default. Settings adds roots,
exclusions and inclusion switches. The packed catalog, dates, sizes and Nook-opened usage are saved with private
permissions in `~/Library/Caches/com.yusuf.nook/FileIndex`; file contents and queries are not saved. FSEvents
replays changes after restart; dropped history or changed journal/scope triggers a rebuild. Descendant symlinks
are indexed as references and never traversed. Previews remain bounded and in memory; cloud-only items show a
Finder download hint. Trash uses `FileManager.trashItem` and refuses configured index roots.

Startup never requests folder permission. Desktop/Documents/Downloads, media folders, Library (including cloud
storage), and removable/network volumes are gated before filesystem access. The native **Allow access** row
(⇧⌘A) and Settings → File Search request Desktop/Documents/Downloads only after a click; successful grants are
remembered. Other protected locations require Full Disk Access, detected by a silent FDA-only sentinel open.
Automatic previews in gated folders show metadata only. Spotlight always uses its symbolic home scope, with
lexical result filtering: explicit protected-folder scopes were found to prompt on macOS. If macOS withholds
those results too, Allow access is required. Additional root symlinks are rejected without following them.

The bundled Files tab is native SwiftUI; a user `files` web plugin can still override it and use this bridge.
Native shortcuts: ↑↓ select, Return opens, ⌘Return reveals, Space toggles Quick Look (Shift-Space types a space),
⌘C copies path, ⌥⌘C copies name, ⌘⌫ requests Trash confirmation, Tab/Shift-Tab cycles kinds, ⌘K opens local
Actions, layered Escape cancels/clears/closes. Rows drag files to other apps. The launcher includes file results
after its other sources; `file:` or `f ` limits it to this shared index. Toggle Files in Launcher Settings.

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

The app and CLI cache `index.json` under `~/Library/Caches/com.yusuf.nook/PluginStore/`. A missing repository displays an empty Store; unavailable networking falls back to saved entries. Installation uses immutable Git trees and verifies blob/tree hashes before moving a staged package into the user Plugins folder. Files use the raw CDN only when their hashes match, with immutable Git blobs as a fallback, so current packages usually need just one GitHub API request. `.nook-store.json` records the installed version and tree SHA. Updates refuse to overwrite unrelated or edited copies, and move replaced copies to Trash. Packages allow only regular non-executable files (200 files, 5 MB each, 20 MB total); no hidden files, symlinks, or unsafe paths. Public GitHub API rate limits can delay downloads. Plugins can run commands as the user, so review source before installing.


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

## Native Launcher

**⌥Space** toggles a native borderless launcher inside the notch when available; an occupied default falls back to **⌃⌥Space**.
Dictation already owns ⌥Space by default, so ⌃⌥Space is the usual initial assignment. If both are occupied, record an available shortcut in Settings.
Change or disable it in Settings → Keyboard Shortcuts → Toggle Launcher, or Settings → Launcher. The latter also
controls sources and clears local launch history. The launcher has no dock item and adds no JavaScript bridge API.
It reuses `nook.actions.register`, the ⌘K fuzzy matcher, AI Commands, and enabled tab/group identities.

Search applications, AI Commands, plugins (including hidden dock items), tab groups, loaded plugin actions, and
Lock Screen / Sleep / Empty Trash / Toggle Dark Mode / Quit Nook. Rows show the app icon, title, subtitle, and kind;
running apps show **Running**. Empty queries show recent items ranked by local launch count and last-used time.
Optional prefixes narrow search: `app:`, `ai:`, `plugin:`, `action:`, `command:`. Prefix matches outrank word starts,
then subsequences, then subtitle-only matches; history breaks ties within each match class.

↑↓ / ⌃N / ⌃P select; Return runs; ⌘Return reveals an app in Finder or opens the target tab without running;
⌘1–9 picks results; ⌘K opens the selected row's actions. Tab or the final **Ask AI** row sends the query to the first
saved agent in Agents. With no available agent/Agents tab, a native Quick AI chat uses the existing Codex login.
The bundled Agents plugin provides a native handoff handler that waits for loading and opens a new chat; no plugin
API was added. Escape dismisses actions/confirmation, backs out of Quick AI, clears search text, then closes.
Clicking outside or toggling again closes; keyboard use holds the notch open without pinning it.

AI Command entry snapshots the external app, clipboard and accessible selection **before** the panel takes focus.
Commands use the normal AI Command execution/output pipeline with that context. Text providers without AX selection
support use the existing selection fallback after the captured external app is restored. Clipboard/query text from
the launcher is never used as the selection. See docs/LIMITS.md for focus and indexing limitations.

### Smart answers (native)

The launcher recognizes local math, units, currency, dates/time zones, colors, integer bases and percentage change.
A confident answer appears above the regular results and is selected first. ↑↓ moves between the card and results;
Return copies its value and closes, ⌘Return pastes into the captured external app, and ⌘K offers **Copy result**,
**Copy expression**, **Copy with units**, plus provider actions. Existing ⌘1–9 shortcuts still address regular results.
The card adds 156 pt; regular results retain scrolling with five visible rows while it is shown. Typing resizes instantly.

Examples: `150 + 20%`, `sqrt(81)`, `5 plus 3 times 2`, `10 km in miles`, `5'11" in cm`, `100f to c`,
`3 cups to ml`, `1.5 GB in MB`, `1000$`, `100 eur to mad`, `time in spain`, `5pm london in new york`,
`2 hours from now in spain`, `now + 90 min`, `in 3 days`, `days until christmas`,
`days between 2026-01-01 and 2026-03-15`, `unix 1792600000`, `now in unix`, `#f90 to rgb`,
`hsl(120,100%,50%)`, `255 in hex`, `0xff in binary`, `from 80 to 100`.

Currency defaults to the current locale's currency (MAD for a Moroccan locale). Only the fixed USD-base rate endpoint
is requested; query text, amounts and currency choices stay on the Mac. Rates are cached under
`~/Library/Caches/com.yusuf.nook/Launcher/answers-currency.json`, with at most one attempt per hour, including failures.
Cached rates work offline and show their source timestamp. First use needs a connection; missing rates show a loading
or unavailable card with copying disabled. The free source updates daily. Currency actions include the attribution link,
[Rates by ExchangeRate-API](https://www.exchangerate-api.com/docs/free). No new JavaScript bridge API is added.

### How to add an answer provider

Add **one Swift file** under `Nook/Services/Launcher/Answers/`, then regenerate the Xcode project. Give the class a unique
Objective-C name, subclass `LauncherAnswerModule`, and conform to `LauncherAnswerProvider`:

```swift
import Foundation

@objc(NookDemoAnswerProvider)
final class DemoAnswerProvider: LauncherAnswerModule, LauncherAnswerProvider {
    let id = "demo"
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? {
        guard context.hasTime, query.lowercased() == "answer demo" else { return nil }
        return LauncherAnswer(expression: query, leftBadge: "Demo", result: "42",
                              rightBadge: "The answer", copyValue: "42", copyWithUnits: "42 things")
    }
}
```

Startup discovers module subclasses automatically, including in optimized builds. **No launcher-view, startup-list,
or other-provider edit is required.** `LauncherAnswers.shared.register(provider)` also supports explicit registration;
registering the same ID replaces it. IDs sort deterministically; the first non-nil answer wins, so grammars should be
specific and return nil for ordinary app/file searches. `LauncherAnswer` owns expression/result text, badges, optional
note/swatch, copy payload, and secondary copy/URL actions. Operators and connector words are dimmed by the generic card.

Providers run on their own serial background queues, with a **2 ms deadline per provider**. The registry waits no longer
than that deadline, discards late answers, skips a still-busy provider, and bounds retries to the latest waiting query.
Check `context.hasTime` during bounded computation. Do no disk/network work in `answer`; prewarm expensive formatters in
module initialization and read cached values. Results are cancellable and checked against the current query/presentation
before publishing. Context supplies a fixed clock, locale and time zone for deterministic tests.

For optional asynchronous work, also conform to `LauncherAnswerRefining` and implement
`refine(for:context:completion:)`. Return a cached answer (or `isAvailable: false` placeholder) synchronously, do the work
outside the answer budget, then call completion to re-evaluate the current query. Protect shared caches and throttle I/O;
callbacks from superseded searches cannot change the card. Test fixtures belong in `tests/answers/`, including positives,
ordinary searches that must return nil, malformed inputs, and warmed timing checks. Run `bash tests/answers/run.sh`.
