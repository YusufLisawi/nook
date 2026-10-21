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
| Show status on the closed notch | `nook.activity.set/clear` |
| Control the notch | `nook.notch.close/pin/setHeight` |
| Take dropped files/folders | `nook.on('drop', …)` gives real paths |
| Ask an LLM | `nook.ai.chat` — uses the user's Groq key (no key → a clear error) |
| Use built-in engines | `nook.proxy.*` (whole-machine proxy), `nook.dictation.*` (Groq dictation) |
| Keep running in the background | the web view stays alive while Nook runs (timers, polling, sockets keep going) |
| React to Nook | `nook.on('open'|'close'|'show'|'proxy'|'dictation'|…)` |
| Get a global shortcut | the user assigns one per tab in Settings → Tabs & plugins |
| Be driven from outside | `nook open|toggle <id>` / `nook://open/<id>` URLs (scripts, Raycast, Shortcuts) |
| Override a built-in tab | ship a plugin with the same `id` (e.g. `home`) |

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

## Native Settings

- Settings has searchable native panes, including panes registered through `SettingsRegistry` with optional keywords.
- Tabs & Plugins uses a master–detail editor for height, hotkey, manifest options, and code customization. Reordering
  writes `PluginRegistry.customOrder`, the same order used by the notch dock. Reverting a plugin uses the Trash.
- Keyboard Shortcuts lists tab shortcuts, AI command hotkeys, dictation gestures, and shortcuts exposed by native
  features through `ShortcutRegistry`. Recorders detect duplicate Nook assignments, including existing conflicts.
  macOS and other apps’ shortcut assignments are not inspectable here; Accessibility is still required globally.
- About shows the app version/build, project links, MIT license, and the shared Sparkle update action.
- The last pane and window frame persist in preferences. The Settings hosting controller pre-warms in a hidden window
  shortly after launch, without activating the app or opening a second instance.
