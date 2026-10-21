# Plugin engine v2 — agent/engine

Phase 1 implements Store-delivered native plugins as separate supervised processes, while preserving existing
web-only v1 plugins. Mouse is the proof: its native implementation is no longer compiled into Nook. No Nook
instance was launched, no GUI automation/input posting was used, and no live Nook Application Support data or
/Applications contents were modified. Nothing was pushed, published or released. Per the lead's follow-up, main at `6221bf0` was merged into this
branch, including the lean agent's shared Features registry and idle-work changes.

## Architecture and behavior

- `PluginManifestV2.swift` is a Foundation-only manifest/capability/path policy shared with the CLI and Store.
  V1 remains supported. V2 supports executable commands, supported interpreter argv, architecture-specific
  helpers, foreground/background lifetime, permissions and all eight contribution categories. Invalid/unknown
  v2 calls fail closed, including attempts to call privileged legacy feature namespaces.
- `PluginRPC.swift` implements bounded UTF-8 NDJSON JSON-RPC 2.0 framing, fragmented/multiple frames, request/
  response validation, error objects and exponential restart policy. Stdout is protocol only; stderr goes to
  `nook logs <id>`. Frames cap at 1 MiB, pending requests at 128, UI-to-helper calls at 15 seconds.
- `PluginHelperProcess.swift` supervises Foundation Process on a serial state queue, with independent pipe
  reading/writing, plugin/data environment, crash isolation and 1/2/4/8/16/32/60-second backoff. Healthy 60-second
  uptime resets the delay. A tiny internal `nook-cli _plugin-exec` trampoline creates a process group then execs
  the helper, retaining pid/stdio and the native launch chain. Disable/revoke/uninstall cancels restarts, closes
  stdin and terminates ordinary descendants, with a two-second SIGKILL fallback. Normal foreground helpers
  stop when the last display closes their tab. Production execution never loads helper code into the app.
- `PluginEngine.swift` connects the shared Features registry, multi-display visibility, helper calls and event delivery.
  The registered `native` and `host` namespaces are the transports. Both web aliases and helper `host.*` requests
  pass through the same capability policy. File edits/registry revisions restart helpers for hot reload. Features and Tabs & Plugins use the same
  state (`plugin:<id>` for discovered plugins); revoke disables that state. There is no engine-specific enable switch.
  Main's lazy web views, 15-second hidden eviction, immediate disabled eviction and cancellation are retained.
  A page on another display keeps foreground host resources alive; background resources follow helper lifetime.
- `PluginHostAPI.swift` exposes notch/activity, clipboard/watch, scoped UTF-8 files/Trash/reveal/open, network,
  notifications, AIBrain completion, SelectionGrabber text/paste, frontmost app/window metadata, allowlisted
  focused AX actions, per-plugin settings/storage, Keychain secrets, shortcuts and contributions. A single
  pre-open hook captures AICommandContext for approved Accessibility plugins; selection/paste restores/refuses
  the original target rather than typing into a web input. AX actions remain a small generic focused-element
  allowlist. Host shell tasks are separately owned/cancelled per plugin and drain both pipes concurrently with
  bounded capture. HTTP and AI tasks are cancelled on stop. No host AI keys are handed to helpers.
- `PluginPermissions.swift` supplies serialized native consent sheets, plain-language capability descriptions,
  explicit unsandboxed/TCC disclosure, selected folder scopes and a grouped Permissions & Trust section in
  Tabs & Plugins. Declarations are not grants. A new helper requires native-code trust even with zero listed
  capabilities. Revocation also disables the plugin persistently. Developer copies are labeled Developer.
- `PluginContributions.swift` owns global Carbon hotkeys (conflict checks + events), launcher entries and async
  prefix answer providers (gated by Launcher + Smart Answers), grouped setting panes, SF Symbol menu-bar buttons, `nook://plugin/<id>/<handler>`
  routes, named activities and background jobs. Launcher items work independently of Keyboard & Open Nook;
  disabling the launcher removes its contributed items/providers without stopping unrelated helper work. Resources are removed on disable/revoke/uninstall. Native
  launcher answers read a 32-query bounded cache; IPC never blocks its 2 ms native provider budget. Enabled
  foreground helpers need their tab open to receive events; use background permission/lifetime for shortcuts,
  jobs, menu-bar or URL events that must reach a helper while closed.
- Store installation extends the existing immutable Git tree/blob verification, staging/locks/local-edit
  protection/rollback and Trash semantics with SHA-256, executable modes and a verified-manifest approval
  callback before app-managed replacement. Node and Swift compute the same canonical digest (documented in
  PLUGINS.md). V2 Store packages require SHA-256. The catalog adds default:true; first successful online bootstrap
  installs missing defaults, daily and Settings-open checks update managed packages, and expanded permissions
  ask before app replacement. Declined defaults are remembered. Offline startup keeps installed/bundled plugins.
  The existing Plugin Store feature owns the daily timer/networking; turning it off cancels both. Preinstall does
  not enable default-off plugins such as Mouse.
- `nook new --native swift|rust|node|python` scaffolds a working helper/control UI. `--output` permits isolated
  projects/tests. `nook dev <path>` safely mirrors and follows edits in Nook's watched plugin folder, refuses
  unrelated/local edits, and never builds or launches Nook. `--once` performs one sync. `nook validate` checks v2
  without executing plugins. Publishing preserves binary executable modes (only fake publishing was tested).

## Mouse proof

Moved `MouseConfig`, `MouseActions`, `MouseEventState`, `MouseScroller`, `MouseFixService` to
`store/plugins/mouse/native/`; removed the in-app bridge/service registration. The previous Mouse HTML/CSS/JS
is now the Store package and uses `nook.native.call('mouse.<method>', {args:[...]})` and native notifications.
The methods and input behavior are retained. Mouse configuration reads old Nook preferences only for migration,
then writes `NOOK_DATA_DIR/mouse.json`. The shared `plugin:mouse` feature and its input Enable setting default off.
A saved native `features.enabled.mouse` choice migrates once to `features.enabled.plugin:mouse`; no native Mouse
factory remains in Features or Services.

`bash store/plugins/mouse/build.sh` builds arm64 + x86_64, combines and ad-hoc signs `bin/helper`. The universal
binary is included so the checked-in Store folder is actually installable without running an install script.
`--probe` and `--protocol-test` deliberately never start an event tap or post pointer/input actions. Tests query
state/errors and EOF shutdown only. The Store marks Mouse as a default; until the updated Store is published,
install the local built folder with `nook dev` in a controlled Nook session. Other bundled web plugins remain.

## What remains in the app binary

Core infrastructure: notch panel/geometry/keyboard focus and dock/group presentation, WKWebView/UI kit,
BridgeRegistry/SettingsRegistry, the shared Features lifecycle registry, permission/storage/Keychain adapters,
helper supervisor/exec trampoline,
Store client/update scheduler, notification/TCC-facing adapters, AIBrain and SelectionGrabber primitives,
settings/login/updater/CLI integration. The synthetic-input marker stays as a shared host-routing primitive.

Phase 1 intentionally also retains **all pre-existing features except Mouse**: native launcher/answer providers,
file index/search/previews, Clips, Windows, keyboard palette, AI Commands, Agents, Dictation, audio mixer, proxy,
link catcher, cleaner bridge, system stats, timers, media, Shelf/Scratch and their existing settings/bridges.
Their v1 web UIs continue working. This is an engine/proof commit, not a claim those features have migrated.
Main's lean implementation is merged: optional native services stay lazy, disabled features reject legacy
bridges, global shortcut routing follows effective availability, and Settings releases its view tree on close.

## Files and merge surface

New code: `Nook/Core/PluginEngine/{PluginManifestV2,PluginRPC,PluginHelperProcess,PluginEngine,PluginHostAPI,
PluginPermissions,PluginContributions,PluginAutomaticUpdates,PluginShellCommand}.swift` and
`cli/swift/{PluginNativeCommands,PluginHelperLauncher}.swift`.

New package/tooling/docs: `store/plugins/mouse/` (moved sources/UI, helper entry/build script/store metadata/binary),
`store/templates/{web,node,python,swift,rust}`, `store/scripts/validate-v2.mjs`, `store/SKILL.md`,
`skill/nook/plugin-v2.md`, root `CONTRIBUTING.md`, `tests/engine/`, and this report.

Small shared hooks: Services start/shutdown (remove Mouse/add engine); WebPluginHost v2 interception/injection/
visibility; one pre-open selection hook in NotchViewModel; one AppDelegate URL case; TabsPane permissions;
SettingsWindowController update check; unregister methods in Extensions/ShortcutRegistry/LauncherAnswers;
NotchKeyboard filtering/routing for engine-owned actions; PluginRegistry v2 validation. These are host boundaries,
not new feature switches. StoreClient/StorePublisher/PluginStore gain digest/mode/approval support; CLI main
adds dispatch/validation/test-directory override. Node validation/index generation, PLUGINS.md, LIMITS.md,
Store README/CONTRIBUTING and the repo skill are updated. Existing test runners/stubs were adjusted for moved
Mouse sources, new Store validator dependencies and engine-owned actions. Merge integration additionally touches
Features (dynamic Mouse ownership/default migration), KeyboardActions (independent extension contribution owner)
and WebPluginHost (visibility/page cancellation). The regenerated project includes main's 1.10.0 release metadata.

`project.yml` embeds templates in app resources, shares the Foundation manifest with the CLI and uses the
existing Xcode 26 warning-free App Intents link-generation approach. No compiler diagnostics are suppressed.
No third-party app/runtime dependency was added. The optional Rust scaffold uses serde_json (and its standard
transitive crates) to parse arbitrary JSON safely; no Rust dependency ships in Nook. Node/Python/Swift scaffolds
use their standard libraries; jsdom is test-only under /tmp, following existing repo conventions.

## Verification

- Required exact Release command was run and succeeds with zero compiler/linker diagnostics. This Mac/Xcode
  still emits the same environment warning documented by the other feature reports: **Using the first of
  multiple matching destinations** (native/Rosetta). Log: `/tmp/nook-engine-merged-build-exact.log`.
- Universal Release build with `-destination 'generic/platform=macOS'` succeeds with **zero warnings of any kind
  and zero errors**; both app/helper architectures remain supported. Log: `/tmp/nook-engine-merged-build-universal.log`.
- `NOOK_ENGINE_CLI="$PWD/build/Build/Products/Release/Nook.app/Contents/MacOS/nook-cli" bash tests/engine/run.sh`:
  warnings-as-errors Swift tests for fragmented/multiple/invalid/oversized JSON-RPC, backoff/reset, permission
  rejection/revocation/native-trust changes, shared Features/tab enablement, malformed manifests, path/symlink/nonexistent-leaf escape rejection,
  bidirectional helper RPC, crash restart, release of a supervisor removed by its owner, production exec
  process-group child cleanup, stopped-call rejection,
  concurrent large shell stdout/stderr, timeout and disable cancellation. Fake local URLProtocol Store covers
  default metadata/offline fallback, Node/Swift hashes, executable installation, missing/corrupt SHA-256,
  permission-increase refusal preserving old code, approved replacement, Trash and saved-data retention.
  Includes Node v2 manifest checks, mocked web facade/scaffold states under /tmp, and inert compiled Mouse RPC.
- `bash tests/engine/cli.sh`: all four native scaffolds validate; Swift and Rust build universal helpers; all four
  answer a Unicode/quoted JSON request and exit on EOF. Isolated dev sync and exec process-group identity pass.
- `bash tests/mouse/run.sh`: 7,000 native config/input-balance/reversal/synthetic-shortcut checks and mocked UI
  error/retry/permissions/learning/remapping/focus/keyboard tests pass. No event tap or native input events posted.
- `bash tests/store/run.sh`: existing client and mocked-publisher regressions pass. `npm --prefix store test`:
  35 tests pass. `node store/scripts/validate.mjs` and index generation pass for Mouse and Word Count.
- `bash tests/keyboard/run.sh`, `bash tests/launcher/run.sh`, `bash tests/tabs/run.sh`: existing native and mocked
  UI checks pass, including 56 launcher and 50+39 tab/shortcut integration checks. `bash tests/features/run.sh`
  verifies the merged lifecycle/default migration, resource release, hotkeys, bridge cancellation and visibility guards.
  These suites were rerun after main integration; logs are `/tmp/nook-engine-merged-*-final.log`.
- Built CLI validation passes for all native templates and Mouse. `git diff --check` passes.

All installs/downloads/Trash/gh submissions in tests use isolated generated fixtures or injected mocks. Nook,
privacy sheets, real AI requests, real global shortcuts, clipboard contents, OS file Trash and physical input were
not exercised. The precise runtime/TCC/UI checks below remain for the lead under the no-launch requirement.

## Lead testing

1. Run the commands above from this branch. For CLI tests use NOOK_SUPPORT_DIR as the included scripts do; do
   not test `nook dev` against live support data accidentally. Confirm the built executable has no MouseFixService
   symbols and the app resources don't contain a bundled Mouse folder.
2. In a disposable macOS account/VM or when deliberately replacing the single existing instance, run the reviewed
   build. Never run two Nooks. Use `nook dev <repo>/store/plugins/mouse --once` for the local built proof, or publish
   the updated Store only through the lead's normal release process. Review the Developer/native capability sheet.
3. With Accessibility denied, inspect the Mouse inline error/retry; explicitly grant the correct identity in System
   Settings and enable `plugin:mouse` in Features/Tabs, then smoothing/learning. Check wheel reversals, trackpad pass-through, extra-button overlap and
   disable while held. Inspect helper PID/logs; disabling the plugin or revoking access must stop it and cancel restarts.
4. Test a scaffold with background:false across two displays: open starts, the last close stops, reopening starts.
   Kill its helper deliberately in the disposable account and confirm backoff/UI ready refresh. Check global shortcut,
   menu-bar, URL, job and grouped settings with declared permissions. Enable Launcher/Smart Answers to test
   contributed items/answers, turn Keyboard off, and verify they still work. Disable either consumer and verify
   resources disappear without reviving that native service. Toggle the plugin from both Settings locations.
5. Inspect consent before Store install/update, added-permission refusal keeping the old version, revocation persisting
   through restart, unchanged-permission silent update, local-edit refusal, offline startup and default preinstall.
   Turning Plugin Store off must cancel the update timer/networking; a preinstalled Mouse remains disabled.
6. Verify selection/paste and frontmost metadata from an explicit plugin action using a disposable editor. Changed/
   closed targets must refuse paste. Check the native permission form's light/dark layout and keyboard/screen-reader flow.

## Risks and phase-1 limits

- Helpers are unsandboxed code running as the user. Host capabilities are not process confinement; direct file/network
  access and escaped daemons are possible. Trust source/binary provenance. The sheet says helpers can use Nook's
  effective TCC grants. Apple attributes requests to responsible code; signing, interpreter and launch ancestry vary.
  This build does not claim verified child Accessibility/microphone attribution without a signed clean-profile test.
  See [Apple DTS: On File System Permissions](https://developer.apple.com/forums/thread/678819). Mouse's checked-in
  binary is a development proof (ad-hoc signed), not a notarized public release.
- Store SHA-256/Git checks prove integrity relative to the catalog, not author identity or safety. Catalog distribution,
  review and binary reproducibility/signing remain maintainer responsibilities. The new Store contents were not published.
- Web v1 retains legacy privileges during migration. V2 currently needs an HTML control entry; no headless-only plugin
  inventory UX, arbitrary native view injection or native menu trees. Named activity declarations use the host's single
  current activity slot. Prefix answers are asynchronous/cached, not arbitrary injected synchronous Swift providers.
- Host files are scoped UTF-8 (4 MB), not an index or an adversarial filesystem sandbox; concurrent external symlink
  changes remain a limit. Native helper direct APIs are intentionally not constrained by these host file scopes.
- Host network uses the existing HTTP adapter/request timeout; microphone/audio recording, low-level devices, indexing,
  CoreAudio and feature-specific operations belong in helpers. Some future OS capabilities still require host metadata/
  entitlements or additional generic adapters. Selection/AX behavior needs manual real-focus validation.
- Defaults are only installed on the first completed online bootstrap. Declined defaults stay uninstalled. CLI Store
  installs/updates verify packages and rely on Nook's first-enable/runtime consent before new capabilities execute.
- The exact destination-unspecified build retains Xcode's host warning. The explicit universal build is warning-free;
  no Intel support was removed or warning suppressed to conceal it.

## Ordered migration plan

Each migration should move implementation/data ownership into a Store helper, preserve/migrate old data read-only,
use a normal web control UI (or a generic host presentation primitive), mark the replacement default, remove its
service/startup/feature bridge from Nook only after compatibility tests, and ensure disable stops all work.

1. **Launcher + answers:** move app discovery, ranking/history, system commands and all seven providers to helper(s).
   Use host hotkeys, notch open/height, launcher items/answers, activity, settings/storage, network, clipboard,
   selection and files. Preserve native responsiveness with cached value results or a generic list renderer; remove
   feature-specific native renderer/index/provider ownership after the plugin replacement is ready.
2. **File search:** move FileNameIndex.c/Swift, FSEvents, Spotlight, filters/ranking and previews to a helper. Use host
   files/scoped-folder consent, settings/storage, launcher contributions, notch and clipboard. Keep the no-startup-
   prompt policy and scope-before-traversal checks; Quick Look/thumbnail UX can be helper windows or a generic host
   preview adapter. Do not keep a second native index running alongside the plugin.
3. **Clips:** move ClipboardHistory, ScreenCaptureIndex, Vision OCR, retention/privacy marker checks and private images
   into a background helper. Use clipboard, files/Trash, settings/storage, windows metadata, accessibility selection/
   paste, notch and activity. Rich image/file pasteboard support should be helper-owned (host v2 clipboard is text).
4. **Windows:** move geometry/history, AX exact-target capture and desktop/Space actions into a Swift helper. Use
   accessibility, hotkeys, windows metadata, notch and settings. Preserve captured-window identity, safe drag release,
   display transforms and TCC refusals; keep private Space heuristics out of generic host APIs.
5. **Keyboard palette:** move feature action indexing/search into a plugin, using launcher contributions, notch open,
   host hotkeys and settings. Keep the host's minimal focus/keyboard navigation and dock presentation as infrastructure.
6. **AI commands:** move saved command definitions/editor, prompt expansion, workflow and history into a helper.
   Use ai.complete, selection/target restoration, clipboard, hotkeys, notch/activity, settings/storage and optional
   notifications. Keep provider authentication/transport in the generic AIBrain host adapter.
7. **Agents:** move AgentService/models/session persistence/Codex CLI orchestration and diff previews into a helper.
   Use shell (or helper-owned child processes kept in its supervised group), files, ai as appropriate, activity/notch,
   launcher and settings/storage. Adapt old nested process-group creation so helper crash/disable cannot orphan Codex.
8. **Dictation:** move recording/history/shortcut state/transcription workflow to a Swift helper. Use microphone,
   accessibility paste, hotkeys, activity/notch, settings and secrets/network. A generic host ai.transcribe adapter
   would preserve shared provider credentials; it is not part of phase-1 ai.complete. Otherwise the helper must
   own explicit plugin credentials. Verify microphone/Input Monitoring/TCC attribution in signed distribution.
9. **Mixer:** move CoreAudio taps, device enumeration and per-app gain into a helper; require appropriate OS audio
   permissions. Use settings/storage, activity, notch, windows metadata and notifications. Restore all routing/gain
   on helper shutdown/crash; no feature audio graph stays in Nook.
10. **Proxy:** move system proxy restore/selection/local forwarder into a background helper. Use network, shell,
    Keychain secrets, settings/storage, activity/notch and notifications. Preserve rollback/system configuration on
    stop; any authorization needed remains explicit and no privileged installer runs automatically.
11. **Links:** move LinkCatcher clipboard filtering/deduplication into a background helper. Use clipboard/watch,
    settings/storage, network.open, launcher and notch. Retain privacy markers/ignore windows; don't duplicate Clips.
12. **Cleaner:** move CleanerEngine/scans/age policy/confirmed actions into a helper. Use files/folder consent/Trash,
    shell only where essential, settings/storage and notch/activity. Preserve protected-skip handling and separate
    explicit irreversible Finder Empty Trash confirmation; don't replace Trash with unlink.
13. **Monitor:** move SystemStats sampling/process metrics/IOKit data into a helper. Use settings, activity/notch and
    background lifetime; sample only while required. Read system APIs directly, rather than adding monitor-specific
    feature state to the core host. Remove the old sampler once v1 system consumers have migrated.
14. **Timers:** move TimerService/modes/saved state into a helper. Use background jobs or its own timer, notifications,
    activity, notch and settings/storage. Wall-clock deadlines and restart recovery preserve timers across updates.
15. **Teleprompter:** already mostly web code; move its package/default delivery to the Store, use notch pin/height,
    settings/storage and optional hotkeys. A helper is needed only for external/global input; don't add native code
    for the existing web scroll loop.
16. **Media:** move MediaController/MediaRemote/Apple Events backends and artwork/transport state into a helper. Use
    network only as needed, settings, activity/notch, notifications and hotkeys. Keep OS usage-description metadata
    in core; helper/provider compatibility and signing/TCC tests travel with the plugin.
17. **Other remaining native tabs (Shelf/Scratch) and bundled Home/Notes packages:** Store-package all defaults;
    move Shelf file references/preview actions into a helper using files/Trash/clipboard/notch, and Scratch into
    plain web storage/settings. Preserve existing drafts/references with read-only migration. Dock/group behavior,
    CaptureShield, basic focus, Store and app update infrastructure remain host concerns, not a new feature service.
