# Settings polish

Implemented on `agent/settings`. No new third-party dependencies.

## Built

- Split the monolithic Settings view into nine panes under `Nook/Views/Settings/`, with shared navigation, window, plugin form, and shortcut helpers.
- Searchable native sidebar with setting keywords, empty search results, and extension panes. Existing `SettingsRegistry.register(...)` calls remain source-compatible; optional `keywords` makes extension settings searchable. Registrations update an already-open sidebar.
- Tabs & Plugins master–detail editor: enable switches, inline height, hotkey, manifest settings, Edit Code / Show Code, Reset Options, and confirmed Revert using the existing Trash implementation. Drag reorder and keyboard-accessible Move Up / Move Down menus write the same `PluginRegistry.customOrder` as the notch dock.
- Keyboard Shortcuts pane: tab, AI command, dictation, and registered extension shortcuts in one place. The shared recorder catches existing conflicts and rejects duplicate recordings, supports Esc/Delete and modifier-only dictation gestures, and pauses global shortcuts only for the current recording session. Dictation defaults can be restored.
- About pane: app icon, version/build, website/GitHub/issues links, full MIT license, and Sparkle update check.
- Grouped forms and semantic colors throughout. Wrapped footers, complete connection/install errors, adaptive prompt placeholders, resizable master lists, accessible action labels, and clearer empty states. Command duplication selects its copy; deleting a command reconciles selection. Unavailable microphones/displays and custom saved model values remain visible in pickers.
- Last pane persists under `settingsLastPane`; window geometry uses AppKit frame autosave `NookSettings`. The hidden hosting controller pre-warms 0.8 seconds after startup without ordering/activating its window. Codex discovery and CLI PATH/install work run off the main thread. Minimized Settings restores when reopened.

## Files touched

- `Nook/Views/SettingsView.swift`: sidebar, search, lazy pane selection.
- New `Nook/Views/Settings/{General,Tabs,Commands,AI,Dictation,Shortcuts,Updates,Tools,About}Pane.swift`.
- New `Nook/Views/Settings/{SettingsNavigation,SettingsWindowController,SettingsShortcutRecorder,PluginSettingsForm}.swift`.
- New `Nook/Core/ShortcutRegistry.swift`: native shortcut registration and normalized shortcut identity.
- `Nook/Core/Extensions.swift`: optional pane keywords and registration-change notification.
- `Nook/Core/PluginRegistry.swift`: seven-line multi-row move overload.
- `Nook/Core/PluginSettings.swift`, `Nook/Core/ToolsInstaller.swift`: moved their existing UI into the Settings folder; kept data/service implementations.
- `Nook/AppDelegate.swift`: delegate Settings window ownership and schedule prewarming.
- `project.yml`, regenerated `Nook.xcodeproj/project.pbxproj`: new source files and Apple's system `AppIntents.framework`. Linking the system framework resolves Xcode 26's “Metadata extraction skipped. No AppIntents.framework dependency found” warning without disabling diagnostics.
- `PLUGINS.md`, `docs/LIMITS.md`: capabilities and native registry contracts; no new JavaScript bridge API.
- `tests/settings-regressions.py`: isolated native model regression harness.

## Verification

```sh
xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build -destination "platform=macOS,arch=arm64" build
python3 tests/settings-regressions.py
git diff --check
```

Release build passed with **zero errors and zero warnings** using the explicit destination above. The requested command without a destination also succeeds; this Xcode version prints “Using the first of multiple matching destinations” because it sees both Mac architectures. An explicit verification destination avoids that tooling notice without restricting the project’s supported architectures. The harness passed **44 checks** against actual Settings/navigation/shortcut/order source files, with in-memory preferences and mocked services. It tests multi-word and accent-insensitive search, pane/shortcut registration replacement, extension routing, pane restoration, dock order persistence/reset/multi-row moves, fn normalization, and cross-category shortcut conflicts and storage adapters.

Nook was never launched. No GUI automation, user Nook data writes, installs, release scripts, pushes, or external messages were performed. No web plugin files changed, so plugin validation/mock-JS testing is not applicable.

## Lead's manual check

Use one Nook instance when testing the built app, after quitting the currently running copy.

1. Open Settings in light and dark appearance. Resize it down to its minimum (980 × 600), then wider; inspect all nine panes, long account/path/error text, prompt chips, and plugin options.
2. Search `microphone`, `login`, `PATH`, and an unmatched phrase; clear search. Open `nook://settings/about` while a search is active and verify the deep link reveals About.
3. In Tabs & Plugins, select native/bundled/custom tabs, change height/options/hotkey, toggle availability, drag first/middle/last rows, and use Move Up / Move Down. Confirm the live dock matches and Reset Tab Order restores manifest order. Test Edit Code and Revert only with a disposable custom plugin copy.
4. In Keyboard Shortcuts, record across categories, try an occupied combination, clear with Delete or the clear button, cancel with Esc, switch recorders, and switch away from the window mid-recording. Confirm dictation/global shortcuts resume. Check modifier-only dictation and restoring defaults.
5. Add/duplicate/delete AI commands and insert placeholders. Inspect empty command state with a disposable command set. Check Codex missing/signed-out/connected states and connection failure text. Check CLI installation results and the missing-PATH state as appropriate.
6. Check Updates and About share Sparkle's availability; inspect project links and expanded license.
7. Resize/move Settings, select a pane, close/reopen, then restart the single app instance: pane and frame should restore. Disconnect/reconnect a display and verify recovery. Startup should not show or focus Settings.
8. For integration, register an extension pane (with and without keywords) and a `ShortcutRegistry.register(id:title:group:get:set:)` entry during service startup. Verify navigation, keyword search, conflict detection, and the extension's own persisted value/execution. Examples are in `PLUGINS.md`.

## Limits and integration notes

- Visual/runtime verification is left for the lead because this task explicitly forbids launching Nook or GUI automation. Build and logic checks were run here.
- Conflict detection covers Nook assignments, including disabled tabs/commands to prevent future ambiguity. It cannot inspect shortcuts belonging to macOS or other apps. Restoring defaults may reveal an existing conflict; it is shown inline. Extension services own shortcut persistence and execution; the registry only provides Settings integration.
- Extension pane and shortcut registrations should run on the main thread and use stable, unique ids. Existing pane registration signatures still work. Shared-file edits are limited to the integration points listed above.
- Settings uses a wider minimum window to keep the sidebar, master list, and inline editor readable. Existing preference keys, command files, manifest settings, dock order, and plugin customization storage are preserved.
