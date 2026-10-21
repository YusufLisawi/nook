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
| Expose new native APIs | Add a case in `WebPluginHost.handle` + rebuild (then every plugin gets it) |

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

`nook.files.*` provides live Spotlight filename search, scope/kind filters, ranked results, bounded text previews,
QuickLookThumbnailing PNG previews, a native Quick Look panel, Finder reveal, open/open-with, and path/file copy.
Settings → File Search controls the default scope, excluded folders, and hidden files. No helper or extra dependency
is required. Queries only see indexed, accessible files; Spotlight Privacy exclusions remain in effect. There is no
fallback filesystem crawl. Broad searches cap candidate enumeration at 20,000, and return `truncated: true`.
Warm cached candidates return immediately; cold index latency depends on Spotlight and mounted volumes, so a universal
sub-100 ms guarantee is not possible. Live queries stop on plugin close, replacement, or inactivity expiry.
See [PLUGINS.md](../PLUGINS.md#file-search-nookfiles) for the bridge contract and lifecycle.

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
