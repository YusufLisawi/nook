# What Nook plugins can and can't do

Plugins are web apps (HTML/CSS/JS) in a WKWebView inside the notch, plus the `window.nook` bridge to native code.
They load at runtime: **no Xcode, no rebuild, no restart.**

## ✅ Can (today)

| Area | How |
|---|---|
| Any UI the web can draw | HTML/CSS, canvas, SVG, WebGL, CSS animations, `<audio>` playback |
| Run anything on the Mac | `nook.shell("…")` runs `zsh -lc` as the user → any CLI, `osascript`/AppleScript (control other apps), files, git, curl… |
| Call any HTTP API | `nook.fetch` — native, **no CORS** |
| Remember things | `nook.storage` (per-plugin JSON, survives restarts) |
| Read the machine | `nook.system()` — CPU, memory, disk, network, battery, thermal |
| Clipboard, open URLs/files, notifications | `nook.clipboard.*`, `nook.open`, `nook.notify` |
| Clipboard history and searchable screenshots/recordings | Store `clips` helper: capture, local OCR, thumbnails, copy/paste, pins and Trash; plugin Settings |
| Show status on the closed notch | `nook.activity.set/clear` |
| Control the notch | `nook.notch.close/pin/setHeight` |
| Take dropped files/folders | `nook.on('drop', …)` gives real paths |
| Ask an LLM | `nook.ai.chat` — uses the user's Groq key (no key → a clear error) |
| Chat with tool-using agents | `nook.agents.*` — saved agents, persistent Codex CLI sessions, streamed tool cards, cancellation; Settings → Agents |
| Use built-in engines | `nook.proxy.*` (whole-machine proxy), `nook.dictation.*` (Groq dictation) |
| Keep running in the background | the web view stays alive while Nook runs (timers, polling, sockets keep going) |
| React to Nook | `nook.on('open'|'close'|'show'|'proxy'|'dictation'|…)` |
| Get a global shortcut | the user assigns one per tab in Settings → Tabs & plugins |
| Move and resize app windows | `nook.windows.state/apply` — layouts, relative display moves, adjacent desktop moves; per-action global shortcuts in Settings → Window Management |

| Open and navigate by keyboard | General → Open Nook (default ⌥⇧⌘Space); ⌘1…9, ⌃Tab/⌃⇧Tab or ⌘[/⌘]; Esc returns focus |
| Join the command palette | `nook.actions.register([{id,title,subtitle?,shortcut?}])`; ⌘K searches loaded plugins' actions, tabs and AI Commands; events `action` / `actionAlternate` |
| Provide list and pill navigation | injected `.nk-roving` / `[data-nk-item]`, arrows, Enter and `nk:alt` for ⌘Enter; focus rings and `data-nk-autofocus` |
| Be driven from outside | `nook open|toggle <id>` / `nook://open/<id>` URLs (scripts, Raycast, Shortcuts) |
| Override a built-in tab | ship a plugin with the same `id` (e.g. `home`) |
| Browse/install community plugins | Native Settings → Plugin Store; `nook search`, `install`, `update`, `uninstall`; `nook://install/<id>` opens details |

Because `nook.shell` exists, **most "native" ideas are still plugins**: control Spotify/Music via `osascript`, read
`~/Library` data, call `gh`/`bb`/`vercel` CLIs, ping servers, run local LLMs, tail logs, etc.

## ❌ Can't (without changing Nook's Swift code)

| Limit | Why / workaround |
|---|---|
| Native SwiftUI views or AppKit controls | Plugins are web views. Make it look native with the `nk-*` kit |
| Draw outside the notch panel (≈ 650 × 80–400 pt) | The panel is fixed. Use `setHeight` up to 400 |
| Custom closed-notch art (album art, waveforms) | Closed state is SF Symbol + short text only (`activity.set`) |
| Register its own global hotkeys / key taps | Users assign a tab shortcut in Settings; plugins can't grab keys system-wide |
| Microphone / camera / screen capture | Not wired into the web view (no permission flow). Dictation is a native engine; use `nook.dictation` |
| Run when Nook is quit | Web views die with the app. Use `nook.shell` to start a LaunchAgent if you truly need a daemon |
| Native drag **out** of the web view to Finder | Drop-in works; drag-out uses the native Shelf tab |
| New permissions (Calendar, Contacts, Location, Bluetooth…) | Needs Info.plist + Swift. Workaround: `shell` to a CLI/`osascript` that already has access |
| Expose new native APIs | Register a namespace in `BridgeRegistry` + rebuild (then every plugin gets it) |

## ⚠️ Things to know

- **Trust:** plugins are *not sandboxed*. `nook.shell` runs anything as you. Only install plugins you'd run as a script.
- **Memory:** each web plugin is its own WebContent process (~30–60 MB). 10 plugins ≈ 0.5 GB. Disable unused ones in Settings.
- **CPU:** a plugin that polls every 100 ms burns battery even while the notch is closed. Poll ≥ 1 s, pause on `close`.
- **One plugin, every screen:** with "All screens" on, each notch has its own web view of your plugin (state is shared only via `nook.storage`).
- **Debugging:** `nook logs <id> -f` (console + uncaught errors), or Safari → Develop → [your Mac] → Nook to inspect a plugin's DOM.
- **Size:** the content area is the hard constraint. Design for 650 × 210 first.
- **Agents:** requires an installed, signed-in Codex CLI (verified with 0.163). Full access defaults to on and bypasses
  approvals/sandboxing; disable it per agent for workspace-write, with approval requests failing non-interactively.
  Commands and MCP tools come from the user's Codex configuration. Model/effort support depends on the account/model.
  Codex streams item snapshots; text/output granularity depends on the CLI. File previews are bounded working-tree
  diffs and may include earlier edits. Histories are local, unencrypted JSON with private file permissions; there is no
  automatic retention limit. Nook cancels local process groups/descendants; remote tools or already-detached daemons
  may continue work. Quitting interrupts active chats; saved Codex sessions can be resumed after reopening.


## Store File Search, Clips and Windows

These features ship as separate, default-off v2 Store plugins, not app services. Install from Settings → Plugin Store,
then enable/approve. Off/uninstalled means no feature helper, timer, watcher, index, answer table or feature hotkey.
The generic panel, permission UI, helper supervisor and native search renderer remain host infrastructure.

**File Search** owns the packed C matcher, FSEvents, cache/frecency, Spotlight, previews and Quick Look. Startup never
requests protected-folder access: Desktop/Documents/Downloads, media/cloud/Library and network/removable roots are
gated before traversal. Choose protected roots in Permissions & Trust; OS TCC may still need approval for the helper.
Spotlight uses symbolic home scope and can return only metadata macOS permits (20,000-candidate fallback limit).
Own-index search has no candidate cap. Symlink roots are refused; descendant links are references, never traversed.
Automatic previews remain bounded (20 KB text). Explicit Open/Quick Look may trigger OS access/download behavior.
Index-cache migration copies old data but changed scope/cache fingerprints require a first rebuild.

**Clips** owns private clipboard copies, privacy markers/ignored apps, 2-second polling, 30-day/500-unpinned defaults,
screenshot/recording indexing and local Vision OCR. Pins survive retention/capacity. Changes replaced within a polling
interval can be missed. Concealed/transient/generated items, text over 1 MiB and images over 32 MiB/40 MP are skipped.
The pre-start clipboard is never captured. UI history uses pages under 1 MiB, snippets up to 16,000 characters/32 paths;
full native Copy/Paste and saved history retain originals. Screenshots stay in place and require an approved folder.
This feature does not capture the screen: reading existing recordings needs folder access, not a new screen-capture API.
Accessibility is required to paste, with original-app focus checked. File-reference/capture deletion trashes originals;
Clear/retention only trash owned images. Migration copies images/history and rewrites only the private image paths.

**Windows** owns all AX layouts, display moves, frame history and Space policy. Accessibility and a movable normal
window are required; app minimum sizes, full screen/Split View and Stage Manager can constrain geometry. The host
captures only an opaque window/process identity before opening; a helper refuses a missing/changed target. Captures
are per notch, including separate pinned displays. Restore is bounded in-memory frame history, not Space history.
Desktop moves use a checked title-bar drag plus the configured Mission Control shortcut; private read-only symbols
identify membership. They require no SIP changes or private mutation API, do not create/wrap desktops, and can fail
for custom title bars, disabled/intercepted shortcuts, All Desktops assignment, user pointer movement or OS changes.
Graceful stop releases a held drag synchronously. SIGKILL/crash cannot run cleanup; verify pointer/window state after a
forced termination. Helpers are universal/ad-hoc signed here; signed clean-profile TCC and live display/desktop tests
remain necessary. Global hotkey conflicts are checked against Nook and known macOS shortcuts; other apps cannot all
be enumerated.

## Native Settings

- Settings has searchable native panes, including panes registered through `SettingsRegistry` with optional keywords.
- Tabs & Plugins uses a master–detail editor for height, hotkey, manifest options, and code customization. Dock/member reordering
  shares the `TabNavigationStore` presentation preferences with the notch dock; existing `tabOrder` remains the base order. Reverting a plugin uses the Trash.
- Keyboard Shortcuts lists tab shortcuts, AI command hotkeys, dictation gestures, and shortcuts exposed by native
  features through `ShortcutRegistry`. Recorders detect duplicate Nook assignments, including existing conflicts.
  Known macOS symbolic shortcuts are checked; other apps’ private assignments cannot be inspected. Accessibility is still required globally.
- About shows the app version/build, project links, MIT license, and the shared Sparkle update action.
- The last pane and window frame persist in preferences. The Settings hosting controller pre-warms in a hidden window
  shortly after launch, without activating the app or opening a second instance.
- Codex/PATH discovery, microphone enumeration, login-item queries, custom icons, plugin options, and explicit plugin
  reload/copy/revert work run outside the UI thread. Status snapshots are reused across pane switches and refreshed
  on activation or request; Settings has no recurring polling timers. File edits take effect in memory immediately,
  with coalesced background JSON writes (up to 150 ms) and a normal-quit flush. Direct changes to cached JSON files
  require restarting Nook; force-quitting can lose the most recent unflushed edit.

## Cleaner permissions and safety

Cleaner scans fixed home-folder cache/log/developer/package roots and optional old Downloads. Unreadable items
are counted and left in place while readable siblings remain measurable and cleanable. An unreadable descendant
keeps its entire immediate candidate directory intact; counts refer to candidates (or an inaccessible root), not
every nested file. Symlink roots/components and immediate symlink candidates are skipped without following them.
Sizes are allocated-byte estimates, can change while apps run, and cover only fully readable candidates.

Normal cleanup uses `FileManager.trashItem` through `nook.cleaner.clean`, so it does not need to read/list
`~/.Trash`. Trash size is shown as unknown. Explicitly confirmed **Empty Trash** uses Finder via AppleScript,
which may require allowing Nook in Privacy & Security → Automation → Finder, but does not require Full Disk
Access just to list Trash. It empties all Trash, including mounted volumes, before newly cleaned files are moved.
If Finder fails or times out, further cleanup stops to keep new items out of a potentially ongoing empty operation.

macOS TCC/SIP, locked files, and ownership can still prevent particular items from being measured or moved.
One inline hint links to Full Disk Access; granting it may expose more candidates and never overrides SIP or Unix
permissions. Protected skips are expected partial results. Other I/O failures remain errors. Homebrew is delegated
to `brew cleanup -s`, which permanently removes its own obsolete files and may report its own failures; its scan
estimate covers the standard `~/Library/Caches/Homebrew` root, not a custom `HOMEBREW_CACHE` location.

## Dock customization and decks

- Hide from Dock is independent of disabling. Hidden plugins remain available through their global shortcut,
  command palette, URL scheme, and native AI/agent opens. Already-loaded web views keep running normally.
- Groups contain at least two configured plugins and appear as one dock item. Members retain their plugin IDs,
  individual shortcuts, settings, and heights. Each deck remembers its last member and can have its own shortcut.
- The deck's pill row adds 34 points of native chrome above the active member's unchanged content height.
  ⌥⌘←/→ and horizontal swipes cycle visible enabled members; ⌃Tab and ⌘[/⌘] cycle dock items. ⌘1…9 counts
  groups once. Hidden members are never cycling/numbered destinations, but direct opens remain supported.
- A plugin belongs to one group. Moving it to another group dissolves a former group with fewer than two members.
  Missing/disabled members stay in saved groups, are skipped at runtime, and return when available/enabled. Groups
  with no visible enabled members leave the dock. Deleting groups preserves member visibility and enable preferences.
- Settings supports group creation/editing, SF Symbol choices, per-group shortcuts, dock/member drag ordering, and
  keyboard-accessible row menus. Corrupt saved group JSON is left intact and reported until explicitly reset.
- All native shortcut assignments share conflict detection, including Open Nook, Window Management, groups, and
  read-only navigation reservations. This does not enumerate private shortcuts in other applications.

## Native search mode

The core keeps a value-only SwiftUI search surface for notch geometry, keyboard/text focus and asynchronous results.
The default-off Store `launcher` helper owns application discovery/cache, ranking/history, commands, Quick AI and all
answer providers. `file-search` contributes from its own single index. Core does no app/file discovery or answer math.
New generic `searchProviders` require `launcher` permission; query work is coalesced per provider/display, replies are
bounded and stale generations are ignored. Prefix `answerProviders` continue to use the bounded async cache.
Local answers remain local except cached exchange-rate fetching; Quick AI explicitly uses the host AI transport and
user credentials. First-enable history/settings/cache migration leaves old defaults/files intact. The current native
renderer uses SF Symbols for generic items rather than loading application icons, and fixed search-mode height.

## Mouse controls

The Store Mouse plugin uses its separate Swift helper for discrete wheel smoothing, reverse/speed/acceleration,
scroll modifiers and extra-button click/hold/drag remapping. It is off by default; enabling or learning requires
Accessibility. Left/right clicks are never remapped. Continuous trackpad/Magic Mouse scrolling passes through.
Settings are global rather than per device/app; a nonstandard device reporting discrete wheel events may be affected.
The optional wheel chatter filter defaults off because a fast direction change can be intentional.

Tap-creation failures appear inline and retry every two seconds while enabled/learning; permission changes recover
automatically when macOS permits. Disabling or finishing learning retains only outstanding swallowed releases,
then tears down the tap. Overlapping button gestures keep release ownership for every button, with the latest gesture
owning the action. Mouse-generated keys bypass Nook shortcuts and dictation state. App Nap is suppressed only during
scroll animation. System permission revocation, process termination, or a hardware disconnect can interrupt physical
input delivery; macOS/device behavior still needs hands-on verification. Mission Control, Spaces and other key actions
follow macOS shortcuts and target-app support. No per-device detection, custom key recorder or per-app rules are added.
Mouse is a regular plugin and uses the existing 12-item dock cap and customization rules.

Notch content attaches immediately for keyboard entry; hover keeps the delayed attachment/fade to avoid native ghosts. Native initial focus
waits for attachment and early typing is replayed after focus is ready; closing cancels pending focus/reveal work.
The launcher's header crossfade/spring and instant resizing while typing are retained. Visual ghosting, actual first-key
focus, and permission toggles require a manual check in a single running Nook instance; automated tests never launch it.

## Store launcher smart answers

All seven providers (math, units, currency, time/place names, color, base, percentage), provider discovery and place
data live in `store/plugins/launcher`. Adding an answer still means adding one provider file. The 2 ms cooperative
provider budget, input limits, cancellation, cached/offline currency behavior and local time-zone rules remain.
Queries are not stored in history or sent for exchange-rate fetching; Quick AI is a separate explicit action.
Native helper code is unsandboxed: host capability gates are not process confinement. TCC can be attributed to Nook,
the helper or launch ancestry depending on signing/macOS; approve the responsible identity in System Settings.

## Plugin engine v2 (phase 1)

V2 plugins can ship native feature code without an app update: an executable or interpreted helper runs in a
separate supervised process, communicating over JSON-RPC stdio. The host exposes one capability-checked surface
to web and helper callers for notch control, activity, global shortcuts, clipboard/watch, scoped UTF-8 files,
network, shell, notifications, AI via AIBrain, selection/paste, frontmost app/window, focused AX actions,
per-plugin storage/Keychain, launcher entries/async answers, settings panes, menu-bar buttons, URL routes and jobs.
See **PLUGINS.md → API v2** for exact supported calls, scopes and contribution shapes.

Mouse is the first migrated feature: its event tap, scroller and button logic are entirely in
`store/plugins/mouse/native/`, built as a universal helper. It is no longer part of the app or bundled plugin
resources. The Store index marks Mouse as a default install. Until the updated Store is published, existing
bundled web plugins continue working, but Mouse requires a built developer/Store install. Its old preferences
are read for migration; new configuration saves only in its plugin data directory. Off-by-default input control
is preserved. No event tap, OS privacy prompt or pointer action runs in the protocol/probe tests.

Host permissions are revocable declarations/consent, **not an OS sandbox**. Unsandboxed helpers can use direct
filesystem/network APIs and Nook's effective TCC grants. Child process attribution depends on macOS responsible
code and signing identity; Terminal tests do not establish Nook's Accessibility/microphone behavior. Test a
signed app/helper in a clean profile before release. Directly executed binaries, interpreters and daemonized
children have additional provenance/TCC limitations. Helpers must stay in their process group, exit on EOF,
and clean up event taps on SIGTERM; normal descendants are terminated on stop/crash. Malicious helpers can
escape those conventions. The Store verifies SHA-256 plus immutable Git objects, not safety or identity.

Foreground helpers stop when the last display closes their tab; background helpers stop when disabled or
revoked. Restart backoff caps at 60 s; outstanding calls fail on exit. RPC frames cap at 1 MiB and pending calls
at 128; web-to-helper requests time out after 15 s. Stdout must contain only protocol frames. Plugin jobs have
1 s minimum intervals and 100-resource limits; no plugins run while Nook is quit. Disabled web views unload
immediately; hidden pages unload after 15 seconds. Foreground v2 page work is cancelled when the last visible
page unloads; enabled background helpers retain their host resources until stopped. Package limits are 200 files/20 MB,
5 MB each; helpers must be under bin/, no symlinks or installation/build scripts are run.

V2 currently uses an HTML entry/control tab. Menu-bar contributions are buttons, not arbitrary native menu trees.
Contributed settings use the existing scalar setting schema. Only prefix-matched async helper answer providers
are supported; their 32-query cache is in memory. Host file APIs are UTF-8 and scoped, not a file-index engine;
external symlink races are not an adversarial filesystem security boundary. Focused AX actions are a small
allowlist; existing exact-window layout APIs remain v1 until Windows migrates. Microphone capture and custom
low-level device/audio APIs belong in helpers. Plugins cannot add entitlements, bypass TCC/SIP, or install privileged
system extensions through the host. Additional OS capabilities may require app metadata/core fixes.

Daily/default installs keep existing packages offline; increased permissions ask before app-managed replacement.
Checks run only while the shared Plugin Store feature is on; off cancels requests and removes the daily timer.
Preinstall does not enable Mouse: `plugin:mouse` shares its enable state between Features and Tabs & Plugins.
Launcher entries require Launcher; plugin answers also require Smart Answers. The keyboard palette can remain off.
No successful online default bootstrap is recorded on failure. CLI installations stage/verify first and request
runtime consent in Nook before privileged use. Store updates refuse unmanaged/local edits; changing permissions
never silently grants a capability. Existing v1 web plugins keep their legacy privileges during migration and must
be source-trusted. All remaining native features still live in the app in phase 1; REPORT.md lists the ordered migration.

V2 host shell commands belong to their plugin: stdout/stderr drain concurrently (1 MiB captured each),
timeouts stop the process group, and disabling/revoking cancels them. In-flight AI tasks are cancelled too.


## Optional features and idle work

- Settings → Features owns optional native lifetimes. The same switch state is reflected in Tabs & Plugins. Disabled
  owners leave the dock, launcher/palette, native Settings panes/rows and shortcut routing, while saved data and shortcut
  assignments remain on disk. The notch and its basic pointer/navigation infrastructure remain available.
- File Search, Clips, Windows and Launcher are optional Store plugins (`default:false`) and their first discovered
  enable state is off. Mouse also remains disabled until enabled. Install through Plugin Store; explicitly enable
  through Features/Tabs & Plugins. Existing settings/history migrate on helper first run, not at app startup.
- Disabling File Search cancels Spotlight clients, removes FSEvents/access/local-key observers, cancels scans between
  filesystem operations, destroys C storage/query cursors, and drops previews. Launcher releases its app index, icons,
  query/watchers and state. Smart-answer location tables are provider-owned and can be released. Enabling Launcher File
  Source is an independent contribution of the enabled File Search helper; Smart Answers is a Launcher plugin option.
- Clipboard and screenshot lifetimes are independent. Off stops clipboard polling, closes the capture-folder descriptor,
  cancels Vision/thumbnail requests and drops in-memory history/OCR data. Saved history and originals remain in place.
  Dictation off cancels recording/transcription, preserves interrupted history for Retry, and drops its in-memory data.
  Audio captures removed by dictation cancellation/retention now use Trash semantics.
- Mixer off removes the exact Core Audio listener blocks, stops its timer, destroys every tap/aggregate device and clears
  icons/levels in memory. Its enforcement poll exists only with a non-default saved app level. Window targets/Restore
  history and lazily opened SkyLight handles are released when Window Management is off. Proxy off finishes system-proxy
  cleanup before closing its forwarder. Agent processes are cancelled and chat/history state is released.
- Plugin hotkeys use host-owned Carbon registrations, removed on disable. The shared global keyboard tap runs only
  for remaining enabled native shortcuts or dictation gestures. Dictation off does not
  reserve its default gestures. Turning Keyboard & Open Nook off removes the palette/Open Nook assignment from runtime;
  other enabled features may still need the shared tap. Saved assignments are retained for re-enable.
- Pointer hover/click-through and fullscreen changes use input/workspace events, with no per-display polling timer.
  Hidden fullscreen panels detach collapsed activity views so their animations stop. Media checks every five seconds
  only while Music or Spotify is running; Link Catcher checks pasteboard change counts every two seconds when enabled.
  Timers tick once a second only while running. Idle features do not suppress App Nap.
- Web views are lazy, disabled tabs unload immediately and hidden tabs unload after 15 seconds for pending saves.
  Monitor/Home/Mixer stop intervals immediately while hidden. System stats sample on demand only for visible callers.
  Store browsing stays lazy; the v2 scheduler checks defaults/updates daily and on Settings open while enabled.
  Disabling Plugin Store cancels its network sessions/update timer. Closing Settings releases its view tree.
- Native work already executing a filesystem/AppleScript/system call may finish that call before releasing its last
  temporary allocation. Cancellation prevents further result publication/work. Framework caches and malloc high-water
  pages are OS-owned, so releasing feature references does not promise a zero-byte process footprint. Detached external
  processes created by plugin scripts cannot be reclaimed reliably. Keep durable plugin state in `nook.storage`.
- `scripts/measure-idle.sh PID [seconds] [output]` measures an already-running **built review copy**, never launches Nook,
  never uses sudo, and rejects `/Applications/Nook.app`. It reports one-core CPU, interrupt/package idle wakeups per second,
  physical footprint and captures top/footprint/sample. Timer stack matches are sample evidence, not a registered-timer
  count. A single-instance, multi-display hover/fullscreen/permission pass and before/after idle measurements remain lead
  review steps; this change was built and tested without launching Nook.
