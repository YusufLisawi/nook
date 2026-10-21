# Keyboard-first Nook

Implemented on `agent/keyboard`, continuing the partial implementation already in this worktree.

## What shipped

- Global **Open Nook** opens the notch under the pointer, makes its nonactivating panel key and focuses the current web or native tab. Keyboard visits stay open when the pointer leaves. Esc dismisses the palette, then in-notch settings, then the notch and releases focus. Resigning key closes a keyboard visit without stealing focus from another window.
- **⌘1…⌘9**, **⌃Tab / ⌃⇧Tab** and **⌘] / ⌘[** navigate enabled tabs in dock order. Existing tab and AI Command shortcuts also work while the panel is key, after Nook's reserved navigation and plugin actions.
- **⌘K** opens an in-notch SwiftUI palette with fuzzy search across tabs, enabled AI Commands and actions registered by loaded plugins. ↑↓ navigate, Enter runs, ⌘Enter opens tab settings / edits the command / emits the plugin's alternate action. Empty searches have a clear state.
- `nook.actions.register([{id,title,subtitle?,shortcut?}])` uses `BridgeRegistry`. Registrations replace that plugin's list, validate input, are scoped natively to the display's web host and are cleared on reload/host teardown. `action` and optional `actionAlternate` events go only to that plugin on that display. Action shortcuts are local to the selected tab.
- Injected `NookUI/nook-keyboard.js` adds `.nk-roving` / `[data-nk-item]`, arrow/Home/End navigation, Enter activation, bubbling `nk:alt` for ⌘Enter, control-inclusive Tab navigation and `data-nk-autofocus`. It preserves row focus through re-renders and skips hidden, disabled and ARIA-disabled rows without consuming editor/slider arrows. The UI kit provides visible focus rings and exposes row actions on keyboard focus.
- Updated Commands, Links, Notes, Home, Mixer, Cleaner, Dictation, Proxy, Teleprompter and Monitor with navigation and relevant footer hints/actions. Mixer sliders support arrows (1%), Shift-arrows (10%) and Home/End. Home tasks support Return to toggle and ⌘Return to edit, with focus returning to the task on save. Teleprompter supports ⌘Return to start/pause while allowing ordinary Return/Space in the editor.
- Native tab dock/header controls have focus rings; media, Shelf, Scratch and Timers have explicit focus entry points. Shelf supports Return to open, ⌘Return to reveal and Delete to remove the reference (never the underlying user file). Timer duration supports arrow keys.
- Filled existing state gaps: Home storage failures now show an inline retry and prevent editing until loaded; timer/save failures are caught. Commands and Mixer show initial loading indicators. No user-file deletion behavior was added.

## Default shortcut and Settings integration

**⌥⌘Space conflicts with Finder search**, per [Apple's shortcut reference](https://support.apple.com/en-ie/guide/mac-help/mh26783/mac). Default to **⌥⇧⌘Space**, checking enabled macOS symbolic shortcuts and trying **⌃⇧⌘Space** then **⌃⌥⇧⌘Space** if needed. Shortcuts in other apps are not discoverable; the General row lets users record, disable or reset the shortcut. If all three candidates are taken, the first remains the configurable fallback.

`Prefs.openNookShortcut` is the key **`openNookShortcut`**. The value is JSON-encoded `TabHotkey` **Data**, using the existing `keyCode`, `modifiers` and `display` fields. Missing key uses the computed default; empty Data disables it. `OpenNookShortcut.current/save` provide access. One `OpenNookShortcutRow()` was added to General; **no Keyboard Shortcuts pane was added**.

## Files touched

New native files:
- `Nook/Core/KeyboardActions.swift`, `KeyboardWebSupport.swift`, `NotchKeyboard.swift`, `OpenNookShortcut.swift`.
- `Nook/Views/KeyboardFocus.swift`, `KeyboardPalette.swift`.

Small integration changes:
- `Nook/AppDelegate.swift`: global shortcut routing, keyboard tab toggles and menu opening.
- `Nook/Core/Services.swift`: action namespace registration.
- `Nook/Core/WebPluginHost.swift`: helper injection, native host ownership and registration cleanup.
- `Nook/NotchController.swift`, `NotchViewModel.swift`: panel lifetime/focus, keyboard visits and fullscreen behavior.
- `Nook/Prefs.swift`: the preference key.
- `Nook/Services/Dictation/HotkeyMonitor.swift`: consume shortcut key-up and repeats, avoiding leaked keystrokes.
- `Nook/Views/SettingsView.swift`: one General row.
- `Nook/Views/Components.swift`, `NotchRootView.swift`, `Tabs.swift`: native focus controls and palette overlay.

Web/resources/docs:
- New `NookUI/nook-keyboard.js`; focus styling in `NookUI/nook-ui.css`.
- New `keyboard.js` in each of the ten plugins listed above; each plugin's `index.html` and main script (`main.js`, or `plugin.js` for Notes/Teleprompter); small styles in Home, Dictation and Proxy.
- `PLUGINS.md`, `docs/UI-GUIDELINES.md`, `docs/LIMITS.md`, this report.
- `project.yml` and generated `Nook.xcodeproj/project.pbxproj`: new Swift files and linked system `AppIntents.framework`. Xcode 26's metadata extraction emits a warning without this system framework; it is linked to meet the zero-warning build requirement. No new third-party app dependency.

## Verification

- Required build: `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build` — **BUILD SUCCEEDED, zero compiler/linker warnings or errors**. Xcode itself emits one destination-selection warning because this Mac offers arm64, x86_64 and Any Mac destinations. Log: `/tmp/nook-keyboard-build-exact.log`.
- Explicit-destination build: the same command with `-destination 'generic/platform=macOS'` — **BUILD SUCCEEDED, zero warnings and zero errors**, including a case-insensitive full-log audit. Log: `/tmp/nook-keyboard-build-final.log`. This is the reproducible warning-free invocation on this host; no architecture support was removed to hide the diagnostic. Confirmed both UI-kit assets are in the built app resources.
- `NOOK_RESOURCES="$PWD" nook validate "$PWD/Plugins/<id>"` — all ten changed plugins pass without warnings.
- `node --check` — shared helper and all JavaScript in the ten plugins pass.
- Mocked DOM/`window.nook` tests run from `/tmp/nook-keyboard-tests/test.cjs` using temporary jsdom tooling. They cover all ten plugins' keyboard paths, registrations and action target selectors; action/alternate event routing for search/focus and command settings; ready/empty/failed bridge responses; no unhandled rejections; disabled/hidden/ARIA-disabled skipping; wrap/Home/End/Tab; Enter/alternate activation; caret protection; re-render focus; Home edit focus; Mixer keyboard volume; and Teleprompter ⌘Return.
- Native tests compile with `-warnings-as-errors` using actual action registry/search/palette-state/shortcut sources against inert service stubs, then run `/tmp/nook-keyboard-tests/native-tests`. Covered registration validation/replacement/clearing, per-display filtering, disabled tabs/commands, fuzzy search/selection, local shortcut parsing and safe default encoding. Sources: `NativeTests.swift` and `NativeStubs.swift` in that directory. No window creation, event posting, service startup or changes to Nook's user data.
- `git diff --check` passes.

## Lead's manual test

Quit the currently running copy before testing this branch's build; never run two copies together.

1. From a text editor on each display, press Open Nook. Confirm the current tab receives the caret/focus, mouse movement does not close it, and Esc returns typing to the editor. Repeat in fullscreen. Switch to a different app/window while the notch is key; it should close without taking focus back.
2. Reorder/disable tabs and verify ⌘1…9 plus both cycling shortcuts follow the dock. Try configured tab and AI Command shortcuts while Nook is key.
3. Open ⌘K, search partial names, move ↑↓, run a tab and a plugin action. Try no matches. Test ⌘Return on a tab, AI Command and a plugin alternate, and Esc back to the current tab. For an AI Command, confirm selection is captured from the previous app after the notch closes.
4. Visit plugins once to load their actions. Exercise Commands pills (←→/Return/⌘Return), Links (↑↓/Return/⌘Return), Notes (search/list/editor), Home task edit/toggle, Mixer volume/mic controls, Cleaner checkboxes and confirmation controls, Dictation expand/copy/retry, Proxy connect/rename, Teleprompter start/pause, and Monitor metric/process navigation. Confirm visible rings and Tab access to secondary controls.
5. Check native media controls, Shelf open/reveal/remove, Scratch typing and Timers mode/start/duration/Pomodoro options. Confirm Shelf removal leaves the source file intact.
6. In General, record a different shortcut, cancel recording with Esc, disable with Delete and Reset. Confirm changes apply without restarting. Test multiple displays: actions and initial focus must stay on the selected display.

## Risks and limits

- Nook was **never launched** during this work. Real AppKit/WebKit focus transfer, macOS global event-tap delivery, fullscreen/multiple-display behavior and final visual layout require the manual pass above. No GUI automation or typing into apps was used; `/Applications` and Nook's Application Support data were not modified. No push, publish or release scripts were run.
- The exact destination-unspecified build command retains the Xcode destination-selection warning described above; all source diagnostics are clean, and the explicit-destination build has no warnings.
- The global shortcut uses the existing Accessibility event tap and needs the same permission as existing Nook shortcuts.
- Web views load lazily, so a plugin's actions become searchable after that plugin has loaded on the display. Static actions targeting unavailable/disabled controls do nothing until those controls are ready. ⌘Return requires an optional `actionAlternate` listener; bundled static actions reuse their primary behavior.
- Keyboard routing intentionally reserves Nook's navigation shortcuts over plugin/global bindings. Other apps' private hotkeys cannot be checked automatically.
- Settings/main-controller changes are intentionally small but overlap shared files; regenerate the Xcode project after combining parallel branches.
