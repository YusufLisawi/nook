---
name: nook-plugin-builder
description: Build a plug-and-play Nook plugin with a web UI, optional native helper process, scoped host APIs, tests and Store packaging. Use for new Nook features or native-feature migration.
---

# Build a plug-and-play Nook plugin

Ship feature code as a plugin. Nook's binary hosts the notch, web bridge, permission UI, helper supervision and
Store client. Native feature logic runs in a separate process, in any language. Existing web-only v1 plugins
still work; new native plugins use API v2. Read `PLUGINS.md → API v2` for the exact host contract and
`docs/UI-GUIDELINES.md` for the UI kit. Both ship in Nook (`nook api`, `nook guide`, `nook limits`).

## Create and run

```sh
nook new my-tool --native node          # also swift, python, rust
# --output ./plugins creates ./plugins/my-tool instead of installing a dev folder
# Swift/Rust: bash ./plugins/my-tool/build.sh before validating
nook validate ./plugins/my-tool
nook dev ./plugins/my-tool              # mirror + hot reload, app must already be running
nook logs my-tool -f
```

`nook dev` watches source/binary changes and mirrors them to Nook's plugin folder; it never builds or launches
Nook. It refuses to overwrite a different plugin or locally edited dev mirror. Ctrl-C stops watching, leaving
the Developer copy installed. Review its native consent sheet before using it. Use `--once` for one sync.
For isolated CLI tests, set `NOOK_SUPPORT_DIR=/tmp/<your-test>/Nook` and `NOOK_RESOURCES` to a directory
containing `templates/` (the Store repo) or built app `Contents/Resources`. Never point a test at live user data.
Don't launch a second Nook instance or type into the user's apps while testing.

Each plugin has `plugin.json`, `index.html` and local JS/CSS. `store.json` supplies author, description,
version, tags and local screenshots for the catalog. Use lowercase/dash ids matching the folder name.

```json
{
  "id": "my-tool", "name": "My Tool", "symbol": "puzzlepiece.extension",
  "version": "1.0.0", "apiVersion": 2, "entry": "index.html", "height": 210,
  "permissions": ["clipboard"],
  "native": {"run": ["node", "helper.mjs"], "background": false, "permissions": []},
  "settings": [{"key":"greeting","label":"Greeting","type":"text","default":"Hello"}],
  "contributes": {}
}
```

Omit `native` for web-only v2. Use `native.command: "bin/helper"` for a compiled universal helper; Nook first
tries `bin/arm64/helper` or `bin/x86_64/helper` if present. `native.command: {"run":["python3","helper.py"]}`
is another interpreter form. Only a relative script/executable inside the plugin is accepted; no symlink escapes,
absolute commands or `node -e`/`python -c`. `run` supports node/python3/ruby/swift/bash/sh with separate argv.
The scaffolded Swift helper compiles for both architectures with system frameworks. Rust uses serde_json for
correct JSON parsing; install both Rust macOS targets before running its build script. No Nook dependency is added.
Node/Python require the runtime installed on the user's Mac. Never run a plugin's installer/build script on install.

`background: false` means only while the tab is open on any display. `true` requires the `background` permission
and runs whenever enabled. Helpers must exit on stdin EOF, clean up on SIGTERM, and keep children in their process
group. Stop/revoke sends termination and escalates after two seconds. Crashes restart with bounded exponential
backoff. Don't daemonize or launch a persistent agent outside supervision. Keep saved state in `NOOK_DATA_DIR`,
not the package folder. Nook passes `NOOK_PLUGIN_ID`, `NOOK_PLUGIN_DIR`, `NOOK_DATA_DIR` and a standard PATH;
it does not expose host AI keys or arbitrary environment variables. Helpers log to stderr (`nook logs <id>`).

## Build a calm keyboard UI

Use vanilla JavaScript and injected `nk-*` kit/tokens. Bundle all code/assets, no CDNs or remote scripts. Canvas
is about 650 × 210 pt, transparent background, black host, one accent, system font, 8 px gaps. The page never
scrolls; `.nk-scroll` lists do. Don't repeat the plugin title or add marketing chrome.

```html
<main class="nk-root">
  <section class="nk-card nk-fill nk-col">
    <div id="loading" class="nk-empty"><i class="nk-spinner" aria-label="Loading"></i></div>
    <div id="empty" class="nk-empty" hidden><b>Nothing yet</b><span>Run a search to begin.</span></div>
    <div id="error" class="nk-error" role="status" hidden></div>
    <div id="list" class="nk-list nk-scroll nk-fill nk-roving" hidden></div>
  </section>
  <button class="nk-btn nk-primary" data-nk-autofocus>Run</button>
</main>
```

Every call is async and can fail: catch errors and show an inline Retry near the failed content. Implement
loading, empty, error and ready states. Prefer buttons/inputs with labels; use Tab, arrows/Home/End with
`.nk-roving` + `[data-nk-item="stable-id"]`, Enter to activate, bubbling `nk:alt` for Command-Enter. Escape belongs
to Nook. Don't steal Command-K or tab/navigation shortcuts. Preserve identity/focus on repaint. Native forms use
SwiftUI grouped Form through contributions; don't reimplement settings in the web UI.

Declare user options in `settings` (toggle/text/secret/textarea/number/select/color), read
`nook.settings.get()` and apply live on `nook.on('settings', values => ...)`. Secret *settings* retain the old
settings-file semantics; use `secrets.*` for actual Keychain secrets. Pin the notch only for explicit ongoing
work, unpin when done, and clear closed-notch activities immediately after work ends.

## One host API from JavaScript or a helper

Web: `await nook.host.call('clipboard.read', {})`. Helper: JSON-RPC `host.clipboard.read` with the same params
object. New web aliases (`nook.ai.complete`, `nook.files.read`, `nook.selection.get`, etc.) accept that same params
object. Existing clipboard/settings/storage/notch/shell/fetch/notify conveniences also work through v2 checks.
Use only declared, approved capabilities. Never request a broad permission for an unrelated convenience.

| Area | Methods / params | Declaration |
|---|---|---|
| Panel | `notch.open/close {}`, `pin {enabled}`, `setHeight {height}`, `activity.set {text,symbol?,color?}`, `activity.clear {}` | approval only |
| Data | `storage.get {key}`, `set {key,value}`, `all {}`; `settings.get/set/open` | approval only |
| Clipboard | `clipboard.read {}`, `write {text}`, `watch {enabled}`; receives `clipboard` events | clipboard |
| Files | `files.read {path}`, `write {path,text}`, `open/reveal/trash {path}` | files + chosen folders |
| Internet | `network.fetch {url,options?}` → `{status,headers,body}`, `network.open {url}` | network |
| Commands | `shell {command,options?:{timeout}}` → `{code,stdout,stderr}` | shell |
| Alerts | `notifications.post {title,body}` | notifications |
| AI | `ai.complete {prompt,provider?,model?,effort?}` → text; Codex/Groq/OpenAI via user's AIBrain | ai |
| Selection | `selection.get {}`, `paste {text,keepOnClipboard?}` | accessibility |
| Focus | `windows.frontmost {}`; `accessibility.perform {action}` (press/raise/increment/decrement/confirm/cancel) | windows / accessibility |
| Credentials | `secrets.get/set/remove {key,value?}`; namespaced Keychain | secrets |
| Shortcuts | `hotkeys.register {id,keyCode,modifiers,title?,display?}`, `unregister {id}` | hotkeys |
| Launcher | `launcher.items {items:[{id,title,subtitle?,shortcut?}]}`, `answers {id,prefix,method}` | launcher |
| Timers | `jobs.register {id,interval}`, `unregister {id}`; emits job | background |
| Logging | `log {level,message}` | approval only |

File APIs use UTF-8 text (4 MB max), relative to plugin data or absolute inside user-chosen folders. Trash user
files; don't unlink them. Network fetch accepts HTTP(S), URL open accepts HTTP(S)/mailto. AI prompts leave the
Mac; explain this in the feature UI when meaningful. Match model to provider. Selection can copy/select all and
paste into the focused app using SelectionGrabber; only invoke from an explicit user action. Test with inert mocks.

## JSON-RPC protocol

Newline-delimited UTF-8 JSON-RPC 2.0 over stdio, not Content-Length. Maximum frame 1 MiB; CRLF/blank lines
accepted. JSON-escape embedded newlines. Stdout is protocol only. A request has id/method/params; a response has
that id plus exactly result or error. Nook uses string ids; helper ids may be strings/numbers. Notifications have
method/params, no id, no response. There are at most 128 pending requests per direction; UI→helper timeout is 15 s.
Nook sends `host.ready {apiVersion,pluginID}` and `host.event {event,data}`. Keep reading while awaiting replies.

```js
// UI
try {
  const result = await nook.native.call('hello', {name: 'Nook'});
  // render result.message
} catch (error) { /* show inline Retry */ }
nook.native.on('progress', ({percent}) => { /* render progress */ });
nook.native.on('ready', () => { /* refresh after helper restart */ });
```

```json
{"jsonrpc":"2.0","id":"1","method":"hello","params":{"name":"Nook"}}
{"jsonrpc":"2.0","id":"1","result":{"message":"Hello, Nook!"}}
{"jsonrpc":"2.0","method":"progress","params":{"percent":50}}
{"jsonrpc":"2.0","id":9,"method":"host.storage.get","params":{"key":"draft"}}
{"jsonrpc":"2.0","id":9,"result":"saved text"}
{"jsonrpc":"2.0","id":10,"error":{"code":-32001,"message":"Permission denied: clipboard."}}
```

Working complete helpers ship in `templates/{swift,node,python,rust}`. Minimal response patterns:

```swift
// Swift — serialize JSON with Foundation, never interpolate user text into JSON.
var response: [String: Any] = ["jsonrpc":"2.0", "id":requestID, "result":["message":"Hello"]]
var bytes = try JSONSerialization.data(withJSONObject: response); bytes.append(10)
try FileHandle.standardOutput.write(contentsOf: bytes)
// Host call: same dictionary with id, method:"host.storage.get", params:["key":"draft"].
```

```js
// Node — readline input; process.stdout exclusively for protocol.
process.stdout.write(JSON.stringify({jsonrpc:'2.0', id:request.id, result:{message:'Hello'}}) + '\n');
// To call host, send method:'host.storage.get', params:{key:'draft'} and correlate its id.
```

```python
# Python — flush every frame; print diagnostics to sys.stderr.
print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":{"message":"Hello"}}), flush=True)
# To call host, send method="host.storage.get", params={"key":"draft"}; handle its response in the loop.
```

```rust
// Rust — serde_json handles arbitrary JSON request ids and escaping.
writeln!(out, "{}", serde_json::json!({"jsonrpc":"2.0","id":request["id"],"result":{"message":"Hello"}}))?;
out.flush()?;
// Host calls use method:"host.storage.get", params:{"key":"draft"} and a distinct request id.
```

For event taps/device services, use a background stdin reader and dispatch method handlers to a running main
run loop; see Mouse's native/main.swift. Plain stdin loops suffice for request/response helpers. Unknown methods
return -32601, bad params -32602, host denied calls -32001. Nook's global events reach helpers as host.event;
helper notifications reach only that plugin's UIs via `nook.native.on`. Don't claim a helper has started until
its state is usable; reconnect UI state on ready/restart.

## Contributions

All sections are arrays of unique `{id,...}` objects, max 100 each. Disabled/revoked plugins lose all resources.

- `hotkeys`: register-shaped objects; CGEventFlags, requires Command/Control/Option and no known conflicts.
- `launcherItems`: `{id,title,subtitle?,shortcut?}`; helper receives action/actionAlternate events.
- `answerProviders`: `{id,prefix,method}`; helper gets `{query}`, returns `{result,copyValue?,section?}`. Async cache,
  loading/error states and a 32-query bound keep native answer rendering responsive. Launcher must be enabled.
- `settings`: `{id,title?}` creates a native grouped pane from the plugin's top-level scalar settings schema.
- `menuBar`: `{id,title?,symbol?}` creates an SF Symbol status button; receives menuBar `{id}`.
- `notchActivity`: `{id}` names available activities; publish active text with activity.set/clear.
- `urlHandlers`: `{id}` accepts `nook://plugin/<plugin-id>/<handler-id>`; receives url `{handler,url}`.
- `backgroundJobs`: `{id,interval}` seconds (1–86400); receives job `{id}` while enabled.

Launcher contributions declare `launcher`, hotkeys `hotkeys`, jobs `background`. A helper-only feature still
needs a small HTML control entry in phase 1. These are host extension points, not arbitrary native view injection.

## Permissions and trust

Declare only required permissions: files, clipboard, accessibility, microphone, network, shell, ai, background,
hotkeys, notifications, launcher, windows, secrets. Declarations don't grant access. The native consent sheet
lists plain-language effects before app-managed Store replacement or first enable; review/revoke in Settings →
Tabs & Plugins. Developer copies are labeled Developer. Added permissions or a newly added helper require fresh
consent. Revoking also disables the plugin, including across app restarts. Host calls without permission reject. CLI installs verify bytes; Nook obtains consent before running them.

**Helpers run unsandboxed as the user.** They can read files/use network directly, run their own code and may use
Nook's effective macOS TCC grants. Host capability gating does not confine a malicious helper. The native sheet
states this. macOS attributes privacy requests to responsible code; signing, service and launch ancestry can
change attribution. Running under Terminal does not establish the signed Nook/helper's permissions. Verify AX,
event taps/microphone in a clean profile with one Nook instance before release. Don't edit TCC databases, grant
permissions through scripts, install launch agents, or bypass SIP. Revocation stops the normal helper group;
no claim is made about deliberately escaped daemons.

## Test, package, publish

1. Test manifest parsing and helpers using pipes with an isolated NOOK_DATA_DIR. Use stderr logs. Include malformed,
   fragmented, multi-frame JSON, errors, disconnect/restart, and stdin EOF. Never use real input events for unit tests.
2. Test UI state and keyboard logic with mocked window.nook in /tmp. Exercise loading/empty/error/retry/ready,
   settings changes, arrows/Tab/Enter/Command-Enter/Escape. No live app or user data is required.
3. Build universal helpers or both architecture folders. Distribute runtime requirements/licenses. For public builds,
   document reproducibility, Developer ID signing/notarization and quarantine behavior. The Mouse build is ad-hoc signed
   as a development proof; it is not a notarized public release.
4. Run nook validate <folder>, Store npm test/validate, and generate the index. App engine checks are in tests/engine.
   Use no hidden files, links, CDNs, path escapes or install scripts. Only bin/ helpers may have executable bits.
   Max 200 files, 5 MB/file, 20 MB total. Build scripts/source can ship as ordinary non-executable files.
5. Add store.json, increment manifest and metadata version together, update screenshots. Catalog generation computes
   immutable Git SHA plus canonical SHA-256 (path NUL mode NUL size NUL bytes in UTF-8 path order). V2 requires SHA-256.
6. Preview nook publish <path>. If the user authorizes submission, nook publish <path> --yes uses gh to create a Store PR.
   Do not push/merge/publish merely because testing passed. Maintainers review source and binary provenance before merge.

Defaults are marked default:true in store.json/catalog. First successful online launch installs missing defaults;
daily/Settings checks update unedited Store packages. Same grants update silently; expanded grants ask first in
app. Existing installs/bundled v1 plugins work offline. Data/settings survive updates/uninstall; old packages go
to Trash. Developer copies never auto-update. Don't bundle migrated native features back into Nook.
