# Settings structure, polish, and performance

Implemented on `agent/settings`. No new third-party dependencies.

## Built

- Split the monolithic Settings view into nine panes under `Nook/Views/Settings/`, with shared navigation, window, plugin form, and shortcut helpers.
- Searchable native sidebar with setting keywords, empty search results, and extension panes. Existing `SettingsRegistry.register(...)` calls remain source-compatible; optional `keywords` makes extension settings searchable. Registrations update an already-open sidebar.
- Tabs & Plugins master–detail editor: enable switches, inline height, hotkey, manifest settings, Edit Code / Show Code, Reset Options, and confirmed Revert using the existing Trash implementation. Drag reorder and keyboard-accessible Move Up / Move Down menus write the same `PluginRegistry.customOrder` as the notch dock.
- Keyboard Shortcuts pane: tab, AI command, dictation, and registered extension shortcuts in one place. The shared recorder catches existing conflicts and rejects duplicate recordings, supports Esc/Delete and modifier-only dictation gestures, and pauses global shortcuts only for the current recording session. Dictation defaults can be restored.
- About pane: app icon, version/build, website/GitHub/issues links, full MIT license, and Sparkle update check.
- Grouped forms and semantic colors throughout. Wrapped footers, complete connection/install errors, adaptive prompt placeholders, resizable master lists, accessible action labels, and clearer empty states. Command duplication selects its copy; deleting a command reconciles selection. Unavailable microphones/displays and custom saved model values remain visible in pickers.
- Last pane persists under `settingsLastPane`; window geometry uses AppKit frame autosave `NookSettings`. The hidden hosting controller pre-warms 0.8 seconds after startup without ordering/activating its window. Codex discovery and CLI PATH/install work run off the main thread. Minimized Settings restores when reopened.
- Continued from the previous run’s committed implementation (`fe2cf57`). Added shared, asynchronous status snapshots for Codex, tools, login items, and microphones. Successful and missing results cache for 30 seconds across pane switches; simultaneous refreshes coalesce, and a change during discovery triggers a follow-up before callers finish. Prewarming starts these probes in the background. Activation, device changes, and explicit Refresh Status actions replace Settings’ polling timers.
- Moved secret/plugin-option reads out of view construction, custom icon loading out of view bodies, and login-item operations off the main thread. Codex caches missing CLI paths, and install/sign-in—including Terminal’s AppleScript launch—are asynchronous with progress and inline errors.
- Secret and plugin-option stores use synchronized in-memory snapshots. AI command, secret, and plugin-option JSON writes coalesce on a utility queue for up to 150 ms. Native consumers and plugin events see edits immediately; normal quit and handled termination signals flush final values. The secret store retains 0600 permissions and all existing file formats/keys.
- Plugin folder copying, Trash-based revert, and Settings-triggered discovery run in the background, with inline failure/progress states. Existing synchronous registry APIs remain available to other features. Fixed duplicate prompt-placeholder insertion during a re-entrant view update, and display row identities when connected monitors share a name.

## Performance evidence

No Nook instance was launched or automated, so full window-open, pane-render, and frame timings could not be measured under the task’s constraints. The following are measured stall sources and isolated production-model timings, not end-to-end UI claims.

Read-only probes on this Mac ran each original `zsh -lic` command three times without printing paths, keys, or auth contents:

| Original synchronous operation | Median | Range | Final Settings path |
| --- | ---: | ---: | --- |
| Codex `command -v` discovery | 1,682.65 ms | 1,467.86–2,262.73 ms | Utility task; cached across pane switches, including missing results |
| Installer-tool discovery | 1,155.63 ms | 1,106.06–1,215.07 ms | Runs only after Install is clicked, off the main thread |
| Command-line PATH inspection | 1,157.85 ms | 1,102.33–1,166.30 ms | Pre-warmed utility task; cached status |

Source tracing showed that the original AI pane initialized `@State` from synchronous Codex discovery (which SwiftUI can evaluate again when constructing view values), and its timer repeatedly discovered missing tools. The intermediate implementation moved status refresh to a task but still repeated shell work, did not preserve snapshots across pane switches, and left installer discovery on the main thread. Microphone enumeration and several file reads also occurred in view initializers/bodies. Fields performed atomic disk writes on every keystroke.

`tests/settings-performance.py` compiles the actual cache/persistence models in Swift 5 mode with warnings treated as errors. On the measured run, 1,000 cached status refreshes averaged **0.0002 ms/call**, with no additional discovery. The same temporary dictionary edited 1,000 times averaged **0.3158 ms/edit** with the previous synchronous atomic-save approach, versus **0.0022 ms/edit** through the production in-memory/background writer. These figures measure caller time; background durability is checked separately by decoding the flushed files. A deliberately 150 ms discovery leaves the main actor responsive before completion. The harness also verifies coalescing, forced refresh during discovery, expiration, missing-tool caching, concurrent edits, live plugin events, reset behavior, and final-file permissions.

## Files touched

- `Nook/Views/SettingsView.swift`: sidebar, search, lazy pane selection.
- New `Nook/Views/Settings/{General,Tabs,Commands,AI,Dictation,Shortcuts,Updates,Tools,About}Pane.swift`.
- New `Nook/Views/Settings/{SettingsNavigation,SettingsWindowController,SettingsShortcutRecorder,PluginSettingsForm,SettingsSnapshot,SettingsPluginActions}.swift`.
- New `Nook/Core/SettingsPersistence.swift`: synchronized JSON snapshots and coalesced utility-queue writes.
- New `Nook/Core/ShortcutRegistry.swift`: native shortcut registration and normalized shortcut identity.
- `Nook/Core/Extensions.swift`: optional pane keywords and registration-change notification.
- `Nook/Core/PluginRegistry.swift`: multi-row move overload and background Settings discovery; existing synchronous call sites remain source-compatible.
- `Nook/Core/PluginSettings.swift`, `Nook/Core/ToolsInstaller.swift`: moved their existing UI into the Settings folder; kept data/service implementations.
- `Nook/AppDelegate.swift`: delegate Settings window ownership and schedule prewarming. `Nook/Core/Services.swift`: secret-store adapter and shutdown flush. `Nook/Services/AI/AICommands.swift`: six-line background-save adapter. `Nook/Services/AI/CodexLink.swift`: synchronized discovery cache and asynchronous Terminal setup with error reporting.
- `project.yml`, regenerated `Nook.xcodeproj/project.pbxproj`: new source files and Apple's system `AppIntents.framework`. Linking the system framework resolves Xcode 26's “Metadata extraction skipped. No AppIntents.framework dependency found” warning without disabling diagnostics.
- `PLUGINS.md`, `docs/LIMITS.md`: capabilities and native registry contracts; no new JavaScript bridge API.
- `tests/settings-regressions.py`: isolated native model regression harness.
- `tests/settings-performance.py`: actual cache/persistence/plugin-setting tests and mocked Codex process discovery, using only temporary files/in-memory services.

## Verification

```sh
xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build -destination "platform=macOS,arch=arm64" build
python3 tests/settings-regressions.py
python3 tests/settings-performance.py
git diff --check
```

Release build passed with **zero compiler/linker errors and warnings**. The requested command succeeds but this Xcode version emits one destination-selection warning, “Using the first of multiple matching destinations,” because it sees both Mac architectures. The explicit-host-destination verification completes with **zero warnings of any kind**, without restricting the project’s supported architectures. The regression harness passed **49 checks** against actual Settings/navigation/shortcut/order/plugin-discovery source files, with in-memory preferences and mocked services. The performance harness passed **22 cache/persistence checks plus 7 Codex discovery checks**. Total: **78 checks**. No test invokes Terminal, installs anything, performs GUI automation, or accesses real Nook data.

Nook was never launched. No GUI automation, user Nook data writes, installs, release scripts, pushes, or external messages were performed. No web plugin files changed, so plugin validation/mock-JS testing is not applicable.

## Lead's manual check

Use one Nook instance when testing the built app, after quitting the currently running copy.

1. Open Settings in light and dark appearance. Resize it down to its minimum (980 × 600), then wider; inspect all nine panes, long account/path/error text, prompt chips, and plugin options.
2. Search `microphone`, `login`, `PATH`, and an unmatched phrase; clear search. Open `nook://settings/about` while a search is active and verify the deep link reveals About.
3. In Tabs & Plugins, select native/bundled/custom tabs, change height/options/hotkey, toggle availability, drag first/middle/last rows, and use Move Up / Move Down. Confirm the live dock matches and Reset Tab Order restores manifest order. Test Edit Code and Revert only with a disposable custom plugin copy.
4. In Keyboard Shortcuts, record across categories, try an occupied combination, clear with Delete or the clear button, cancel with Esc, switch recorders, and switch away from the window mid-recording. Confirm dictation/global shortcuts resume. Check modifier-only dictation and restoring defaults.
5. Add/duplicate/delete AI commands and insert placeholders (each click inserts exactly once). Type rapidly in a long prompt, API-key fields, and plugin text options; switch panes and quit immediately after an edit, then reopen the single instance to verify the final value. Inspect empty command state with a disposable command set. Check Codex missing/signed-out/connected states, Terminal launch errors, Refresh Status, and return from Terminal after sign-in. Check CLI installation results and the missing-PATH state as appropriate.
6. Check Updates and About share Sparkle's availability; inspect project links and expanded license.
7. Resize/move Settings, select a pane, close/reopen, then restart the single app instance: pane and frame should restore. Disconnect/reconnect a display and verify recovery. Startup should not show or focus Settings.
8. For integration, register an extension pane (with and without keywords) and a `ShortcutRegistry.register(id:title:group:get:set:)` entry during service startup. Verify navigation, keyword search, conflict detection, and the extension's own persisted value/execution. Examples are in `PLUGINS.md`.
9. Open/close Settings repeatedly and switch among General, ChatGPT & Codex, Dictation, and Command Line while discovery is slow. Cached content should appear immediately, fields must stay responsive, and no polling should continue while Settings is idle. Connect/disconnect a microphone and inspect the picker. With a disposable plugin copy, verify Reload/Edit Code/Revert stay responsive and report filesystem failures inline.

## Limits and integration notes

- Visual/runtime verification is left for the lead because this task explicitly forbids launching Nook or GUI automation. Build and logic checks were run here.
- Conflict detection covers Nook assignments, including disabled tabs/commands to prevent future ambiguity. It cannot inspect shortcuts belonging to macOS or other apps. Restoring defaults may reveal an existing conflict; it is shown inline. Extension services own shortcut persistence and execution; the registry only provides Settings integration.
- Extension pane and shortcut registrations should run on the main thread and use stable, unique ids. Existing pane registration signatures still work. Shared-file edits are limited to the integration points listed above.
- Settings uses a wider minimum window to keep the sidebar, master list, and inline editor readable. Existing preference keys, command files, manifest settings, dock order, and plugin customization storage are preserved.
- The background writer flushes on normal quit and handled SIGTERM/SIGINT/SIGHUP. A crash or SIGKILL can lose unflushed edits (normally the last 150 ms). Direct external changes to cached plugin-setting/secret JSON files require a restart; edit through Settings/the bridge for immediate synchronization. File formats are unchanged.
