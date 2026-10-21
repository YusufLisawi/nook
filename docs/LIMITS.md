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
| Clipboard history and searchable screenshots/recordings | `nook.clips.*`: native capture, local OCR, Quick Look thumbnails, copy/paste, pin, open/reveal, Trash; Settings → Clipboard |
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


## Window management limits

Window actions require Accessibility and an app that exposes a movable/resizable focused AX window. Layouts use each
display's `visibleFrame`, leaving the menu bar and Dock available. App minimum sizes and fixed-size windows can prevent
a layout; Nook reports the constraint and retains a Restore frame. Stage Manager's recent-app strip is not separately
reserved. Maximize is a frame resize, not native full screen. Restore is in-memory geometry history, not Space history.

Desktop moves use a title-bar drag plus the configured macOS Mission Control shortcut, with Space membership verified
afterward. This works without changing SIP and follows the window to the adjacent desktop; it does not create desktops
or wrap. Leave full screen/Split View, disable an app's All Desktops assignment, and release shortcut keys before moving.
Custom title bars, a disabled Mission Control shortcut, third-party shortcut interception, user pointer movement, or macOS
animation/behavior changes can prevent a move. When Nook cannot safely identify a title bar or confirm the result, it
reports an error and releases the drag; check Mission Control if the desktop changed but the window did not.

Read-only SkyLight/AX symbols identify Spaces and window membership. They are resolved at runtime and can disappear
in a future macOS release, in which case desktop moves fall back to an explanatory error and manual Mission Control.
Nook does not use private Space mutation APIs, SIP exemptions, code injection, or helpers. Hands-on macOS 26 testing
remains necessary for each app's title bar. Other applications' global shortcuts cannot be enumerated; Settings blocks
conflicts within Nook and known/enabled macOS keyboard shortcuts. ⌃⌥ plus a key cancels the default dictation hold.


### Clipboard and screen-capture history

The bundled **Clips** tab uses native services through `nook.clips` (see `PLUGINS.md`). Clipboard capture polls
every 750 ms while Nook runs. It skips concealed, transient, and autogenerated pasteboard markers, ignored
frontmost applications (1Password, Bitwarden, Keychain Access by default), and Nook's temporary AI clipboard use.
Rich text becomes plain text; PNG/TIFF images get private PNG copies in `Clips/Images`. Defaults are 30 days and
500 unpinned items; pins survive both limits. Age pruning runs at least once a minute while Nook runs.
Text over 1 MiB and image representations over 32 MiB / 40 megapixels are skipped. Changes faster than the polling
interval may be missed. The pre-launch clipboard is deliberately not captured.

Screenshots/recordings are indexed in the macOS screenshot location (normally `~/Desktop`), or the Settings override.
Only this folder's immediate regular image/movie files are scanned: names matching common screenshot/recording
patterns or Spotlight's `kMDItemIsScreenCapture`. Renamed files need Spotlight metadata; unsupported localized names
without that attribute may be missed. The directory is watched with a short settle delay and rescanned every 30 seconds.
The newest 2,000 unpinned captures plus pins are indexed; files are never removed by this limit. Folder access may need
Files & Folders permission. Quick Look creates bounded in-memory thumbnails; Vision recognizes screenshot text locally
one image at a time and caches results, including empty/unsupported results until the file changes. Recordings have
thumbnails and filename search, without video OCR. Turning OCR off stops new work; cached text stays searchable.

`copy` preserves images as image data. `paste` closes the notches, activates the last external app, and sends ⌘V only
after verifying that app still has focus; Accessibility permission is required. Quick Look and interactive paste still
need manual verification on a running app. `delete` moves associated files (including original file references) to Trash.
Clear/retention only remove clipboard entries and Nook's image copies. Screenshot originals and referenced files stay
in place during clear/retention. Clipboard text and OCR caches are stored locally with user-only file permissions;
they are not encrypted separately from the user's account.

- **Store:** the public GitHub catalog is cached for offline browsing; installing/updating requires GitHub and is subject to its public API rate limits. An unpublished repository is shown as an empty Store. Packages are pinned to Git tree hashes and limited to 200 regular non-executable files, 5 MB each, 20 MB total. Updates refuse local edits; replaced/uninstalled copies go to Trash while saved data remains. `nook publish <path>` previews a validated contribution and requires `--yes` before using authenticated `gh` to fork, branch, upload, and open a PR. Store validation is a packaging/UI check, not a security review.


## Native File Search

Files uses a native SwiftUI tab and its own packed, in-memory name index, shared with `nook.files.*` and the
launcher (`file:` / `f ` prefixes). It searches names, not file contents. Newest added/modified files appear
in Recent even if never opened; name-match tiers dominate recency/frecency on nonempty queries. Date Added
uses the filesystem's added-to-directory date, falling back to creation; filesystems/providers may omit it.

Home is indexed by default, excluding Library, hidden files, dependencies/caches/builds and common app/package
contents. Native Settings configures additional folders, exclusions and inclusion switches. Common package and
kind recognition uses extension heuristics; custom package extensions can be explicitly excluded. Root and
descendant symlinks are never followed; paths are normalized lexically without filesystem probes.

Permission requests are opt-in. Without Full Disk Access, startup excludes Desktop/Documents/Downloads,
Pictures/Movies/Music, Library (including iCloud Drive/Mobile Documents/CloudStorage), and removable/network
mounts before stat/open. Include Library and additional roots cannot bypass this gate. The native Files row
(⇧⌘A) and Settings → File Search explicitly request Desktop/Documents/Downloads, remembering only successful
directory reads. A denied request is not retried at startup. Forget Folder Access removes Nook's remembered
choice, not the macOS TCC grant. Previously successful grants are reused; there is no public silent per-folder
preflight, so if TCC is reset separately, forget Nook's choice before the next launch. Full Disk Access is tested
by opening (without reading) the TCC database, which silently denies access when unavailable. All detection,
root validation, scanning and persistence run off main; the UI and query queue do not wait for a disk walk.
Pictures/media, cloud data, Library and removable/network roots require Full Disk Access. Mount-table exclusions
and a C scanner device boundary prevent walking onto mounted volumes beneath the home folder.

Spotlight uses only NSMetadataQueryUserHomeScope; explicit Desktop/Documents/Downloads scopes caused TCC
prompts in an independent, non-FDA standalone probe on this Mac and are not used. The symbolic home query
completed without a folder prompt, but macOS withheld protected-folder rows in that probe. Results macOS does
expose are merged into Recent and queries with the same ranking, including in the launcher. Withheld results
require Allow access; this cannot be bypassed safely. Spotlight Privacy does not exclude names from the own
index: use File Search's exclusions. Automatic previews never open a gated path; explicit Open/Quick Look may
request access in response to that action. Cloud previews still require availability; no bulk downloads occur.
The Clips screenshot watcher shares the access gate, so it cannot request Desktop access at startup either.

The private binary catalog under `~/Library/Caches/com.yusuf.nook/FileIndex` stores names/paths, sizes, dates,
Nook-opened counts/dates and an FSEvents watermark, without contents or query history. It loads at launch and
replays events missed while quit. Changed scope/journal identity, corrupt cache, root changes or lost FSEvents
history cause a background rebuild. Updates normally settle within FSEvents' 150 ms batch interval plus disk
work. Large directory moves, rebuilds and cache compaction can take longer; merging a very large subtree briefly
shares the search lock. Checkpoints are throttled to five seconds, with a normal-quit flush. Force quitting loses
at most uncheckpointed Nook-opened history; filesystem changes replay from the older watermark.

The own index searches all candidates and returns up to 100 rows. A character mask, C/NEON matching, bounded
ranking heap and complete-candidate incremental narrowing avoid Spotlight latency. Benchmarks cover this Mac's
home folder and one million synthetic names (see docs/reports/files2.md); they measure the engine, not rendered-frame
latency. Larger catalogs/complex OR queries, busy disks, network volumes or permission prompts can exceed one
frame. Paths are bounded to 4,095 bytes and traversal to 256 levels; the string table uses 32-bit offsets.
During builds and for gated folders, Spotlight provides partial candidates capped at 20,000; filters are applied
with the same query compiler. Coverage depends on Spotlight Privacy, importer metadata and macOS access.

Native actions include bounded text/Quick Look thumbnail previews, Quick Look panel, open/reveal, path/name
copy, file drag-out and explicitly confirmed Move to Trash. `nook.files.trash(path, {confirm:true})` requires
caller confirmation and uses `FileManager.trashItem`; configured roots cannot be trashed. The plugin bridge
retains open-with and file-URL copy. The native Files tab can still be overridden by a user web plugin.
See [PLUGINS.md](../PLUGINS.md#file-search-nookfiles) for syntax, lifecycle, settings and keyboard controls.

- **Keyboard:** the global Open Nook shortcut uses the existing Accessibility event tap. Plugins' action
  shortcuts only work inside their selected tab. macOS symbolic shortcuts are checked for the default;
  private shortcuts in other apps cannot be discovered. Actions appear once a plugin has loaded on that
  display; disabled tabs are excluded. ⌘Enter sends the optional `actionAlternate` event.


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

## Native Launcher

- The launcher is a SwiftUI mode of the existing notch panel (720 pt content width; up to eight visible rows).
  It shares the notch shape/spring, CaptureShield, keyboard key-panel behavior and held hit rectangle. It does not
  add a dock tab or a separate launcher window. Selection is a soft rounded white tint; search has no border or ring.
- Apps are discovered on a utility queue from `/Applications`, `/System/Applications`,
  `/System/Applications/Utilities`, `~/Applications`, running apps and Spotlight's application-bundle index.
  FSEvents and live Spotlight updates refresh discovery. Spotlight Privacy, unmounted volumes and unreadable folders
  can limit discovery; standard folders still work without Spotlight. Application metadata and 64 px PNG icons are
  cached in `~/Library/Caches/com.yusuf.nook/Launcher`; icons are loaded lazily off the UI thread.
- Launch counts/last-used dates are bounded to 500 entries and saved in Nook preferences. Queries, selected text,
  and Quick AI answers are not included in recents. Clearing recents removes this history. Cold indexing and AX
  responsiveness depend on macOS/other applications; the <50 ms first-frame target still requires an interactive
  measurement on the lead's running build. Prepared filtering of 500 apps is covered by a <5 ms performance test.
- The global shortcut needs the existing Accessibility permission. Defaults check enabled macOS shortcuts and
  Nook's registered/tab/group/AI/dictation assignments before trying ⌥Space then ⌃⌥Space. If both
  are occupied it starts unassigned; record an available shortcut in Settings. Private shortcuts belonging to
  Raycast or other apps cannot be enumerated. Settings can change or disable the assignment.
- AI Commands snapshot accessible selected text before focus changes; unselected native text inputs snapshot their
  contents and restore their selection when executed. Providers that do not expose AX selection use the existing
  clipboard fallback after restoring the captured app. An app that has quit cannot receive output. Remote AX
  providers may time out; nonstandard editors may need an explicit selection. Clipboard fallback and replacement
  still require Accessibility and a usable original input. Existing command output modes/providers remain intact.
- Plugin actions appear after their plugin has loaded on that display; disabled tabs' actions are excluded.
  ⌘Return opens the action's plugin without emitting an action. The first saved agent is the Quick AI default;
  the bundled Agents tab must be enabled and finish loading. Agent failures remain inline. Native Quick AI fallback
  requires the existing ChatGPT/Codex login and model access, and is an ephemeral chat rather than saved agent history.
- Empty Trash (Finder), Sleep and Quit require a second explicit activation; Escape cancels. Finder emptying applies
  to all mounted volumes and may need Automation permission. Dark Mode uses System Events and may also need
  Automation permission. Lock Screen sends macOS's ⌃⌘Q shortcut through the existing Accessibility capability.
  These system operations are never part of indexing or automated tests. Quit follows Nook's normal shutdown path.

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

## Native launcher smart answers

- Smart answers run locally without AI. They never replace normal search results. The native card, actions and height
  changes are shared by every provider; adding a file that subclasses `LauncherAnswerModule` and conforms to
  `LauncherAnswerProvider` installs a new provider after rebuilding. Web plugins do not inject native answer providers.
- Answer queries are bounded to 512 UTF-8 bytes. Every provider runs off the main thread on a serial queue with a 2 ms
  result deadline; late answers are ignored and busy providers cannot accumulate work. Swift cannot forcibly stop a
  provider function: a slow implementation can finish in its own queue, while later searches skip it. OS scheduling is
  not a real-time guarantee. Providers must use bounded computation/caches; shipped warmed p95 timings are tested below 2 ms.
- Math is a hand-written, finite-result, depth/token-bounded parser, never NSExpression/eval. Unary functions require
  parentheses, trig uses radians, `log` is base 10, and `ln` is natural log. `%` is percentage (not remainder): `150 + 20%`
  adds 20% of 150. Power is right-associative and binds before unary minus. Bare numbers and unknown names are not answers.
  Both decimal separators work; a single comma means a decimal mark, while mixed marks use the final mark as decimal.
  Floating-point rounding and a 13-significant-digit copy limit apply; this is not arbitrary-precision arithmetic.
- Unit conversions cover length, mass, volume, temperature, speed, area, bytes/bits, durations, energy, pressure and angle.
  Cups/spoons/gallons/pints/fluid ounces are US measures unless explicitly `imperial gallon`. KB/MB/GB are decimal;
  KiB/MiB/GiB are binary. Below-absolute-zero temperatures and incompatible dimensions are rejected. Implicit conversions
  prefer the locale's measurement system, using the counterpart when already in that system. Months/years are not fixed
  duration units. Currency symbols/aliases take precedence over ambiguous bare unit names such as `pounds`.
- Currency is the only network-backed answer. The fixed, no-key ExchangeRate-API USD feed supplies cross rates, refreshed
  at most hourly (daily source updates); failures are throttled too. Only rate/cache timestamps persist alongside the
  rates in the disposable Launcher cache. No amounts/queries are transmitted or saved. Offline use keeps the last good
  rates with an age/Offline note. First use without cached rates shows unavailable/loading instead of invented values.
  Copying is disabled in those states. The source attribution link is in currency actions. Rates are indicative.
- City names and IANA identifiers use macOS time-zone data; bundled country aliases use capitals/mainland zones (Spain =
  Madrid, US = New York, Australia = Sydney). Specify a city/IANA ID for another region. Zone conversions use today's date
  in the source zone; nonexistent DST times are rejected, repeated times use the first occurrence. Relative days/weeks
  use calendar days in the destination zone; hours/minutes/seconds use elapsed time. Time output is 24-hour; Unix means
  seconds. Date differences count Gregorian calendar days in the local zone; Christmas means the next December 25.
- Colors accept opaque #RGB/#RRGGBB, integer RGB and HSL. Base conversion supports signed magnitudes up to UInt64.max,
  with 0x/0b/0o prefixes; no fractional bases or two's-complement inference. Percentage change uses the absolute starting
  value as denominator and rejects a zero start. Unsupported/invalid expressions simply leave regular results visible.
- Return copies and restores the original app; Command Return checks Accessibility and the captured application's identity
  before sending Command V. It leaves the result on the clipboard. If the app quits or loses focus, no paste is sent.
  Real focus/paste, screen-reader behavior, multi-display layout and notch resizing still need manual review in a single
  running Nook instance; automated tests use inert output and offscreen rendering, never launch Nook or type into apps.

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
1 s minimum intervals and 100-resource limits; no plugins run while Nook is quit. Web views retain existing
lifetime behavior; stopping a helper does not unload a legacy web view. Package limits are 200 files/20 MB,
5 MB each; helpers must be under bin/, no symlinks or installation/build scripts are run.

V2 currently uses an HTML entry/control tab. Menu-bar contributions are buttons, not arbitrary native menu trees.
Contributed settings use the existing scalar setting schema. Only prefix-matched async helper answer providers
are supported; their 32-query cache is in memory. Host file APIs are UTF-8 and scoped, not a file-index engine;
external symlink races are not an adversarial filesystem security boundary. Focused AX actions are a small
allowlist; existing exact-window layout APIs remain v1 until Windows migrates. Microphone capture and custom
low-level device/audio APIs belong in helpers. Plugins cannot add entitlements, bypass TCC/SIP, or install privileged
system extensions through the host. Additional OS capabilities may require app metadata/core fixes.

Daily/default installs keep existing packages offline; increased permissions ask before app-managed replacement.
No successful online default bootstrap is recorded on failure. CLI installations stage/verify first and request
runtime consent in Nook before privileged use. Store updates refuse unmanaged/local edits; changing permissions
never silently grants a capability. Existing v1 web plugins keep their legacy privileges during migration and must
be source-trusted. All remaining native features still live in the app in phase 1; REPORT.md lists the ordered migration.

V2 host shell commands belong to their plugin: stdout/stderr drain concurrently (1 MiB captured each),
timeouts stop the process group, and disabling/revoking cancels them. In-flight AI tasks are cancelled too.
