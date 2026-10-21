# Tab navigation and merged-feature integration

Implemented on `agent/tabs` for lead review. No new application dependencies or JavaScript bridge namespace.

## Built

- A presentation layer above plugin IDs: `NotchViewModel.tab` remains the active plugin ID. `DockLayout` computes standalone/group dock items, numbered destinations, ordering, and wrap navigation independently of AppKit.
- **Hide from dock** is separate from enabling/disabling. Hidden plugins stay reachable through their shortcut, ⌘K, `nook://open/<id>`, and existing native AI/agent opens. Already-loaded web views remain alive. Hidden plugins are omitted from numbered and cycling destinations.
- JSON-persisted groups with a name, SF Symbol, two or more configured members, optional global hotkey, ordered members, and remembered last member. One group = one dock icon; member hotkeys open that member inside its deck. Group hotkeys toggle the last enabled member, including a directly used hidden member.
- A calm native pill switcher above the content, horizontal overflow scrolling, and ⌥⌘← / ⌥⌘→ plus horizontal swipe deck navigation. ⌃Tab / ⌃⇧Tab and ⌘[/⌘] move between dock items. ⌘1…9 counts groups once. Dock/numbered entry skips a remembered hidden member; direct opens retain its selected pill. Member canvas height is unchanged; deck chrome adds 34 points. The panel accommodates a 400-point member plus deck chrome.
- Tabs & Plugins retains the master–detail editor, with separate Enable / Hide toggles, New Group sheet, named symbol choices, member selection and hotkey recorder, expandable groups, dock/member drag ordering, keyboard-accessible Move Up / Down menus, removal/editing/deletion, and unavailable-member recovery. Deleting a group preserves member enable/hide preferences. Right-click dock icons expose Hide from Dock, Add to Group, and Settings.
- Existing `holdRect` protection remains on all `tab` changes and is used by deck pills, keyboard, swipes, and dock selection. Group presentation changes also preserve the old hit rectangle. Slide directions follow dock/deck order.
- Unified shortcut integration: Open Nook and **all 23 Window Management actions**, including unassigned actions, register with `ShortcutRegistry`. General, Window Management, group sheets, and Keyboard Shortcuts share the Settings recorder. Cross-feature conflicts include tabs, groups, AI commands, dictation, Open Nook, windows, and 17 read-only navigation bindings. Known macOS bindings are checked; restoring defaults also checks conflicts. Window shortcuts used inside a notch target that display's captured external window.
- The earlier keyboard agent's temporary `/tmp` harness is now reproducible under `tests/keyboard/`; File Search also has a repeatable runner. No web plugin behavior was changed.

## Files touched

New feature files:

- `Nook/Core/TabNavigation.swift`, `TabNavigationStore.swift`, `TabNavigationViewModel.swift`, `NativeShortcutIntegration.swift`.
- `Nook/Views/DockNavigationViews.swift`.
- `Nook/Views/Settings/TabNavigationList.swift`, `TabGroupEditor.swift`.

New tests/runners:

- `tests/tabs/{NavigationTests,ModelStubs,IntegrationTests,IntegrationStubs}.swift`, `run.sh`.
- `tests/keyboard/{NativeTests.swift,plugin.cjs,run.sh}`.
- `tests/files/run.sh`.

Shared integration:

- `Nook/Prefs.swift`: three new presentation preference keys.
- `Nook/Core/Services.swift`: one startup registration line; `Nook/AppDelegate.swift`: group shortcut routing.
- `Nook/Core/{NotchKeyboard,OpenNookShortcut,ShortcutRegistry}.swift`: dock/palette navigation, shared recorder adapter, optional default/read-only registry fields.
- `Nook/{NotchViewModel,NotchController}.swift`: group navigation and hit-area integration, panel height.
- `Nook/Views/NotchRootView.swift`: deck row; extracted dock into the new file.
- `Nook/Views/Settings/{TabsPane,ShortcutsPane,SettingsShortcutRecorder,SettingsNavigation,GeneralPane}.swift`: feature UI wiring, recorder/conflict adapters and copy/search terms.
- `Nook/Services/Windows/{WindowManagementPane,WindowShortcuts,WindowManager}.swift`: shared recorder/conflicts and captured-target shortcut routing. Removed the duplicate window recorder.
- `tests/settings-regressions.py`: include the new model dependencies in its isolated harness.
- `PLUGINS.md`, `docs/LIMITS.md`, `docs/UI-GUIDELINES.md`, generated `Nook.xcodeproj/project.pbxproj`, and this report.

## Verification

All pre-existing suites passed against the merged tree before implementation. All suites passed again after integration:

```sh
bash tests/Agents/run.sh
sh scripts/test-clips.sh
bash tests/files/run.sh
bash tests/store/run.sh
npm --prefix store test
node store/scripts/validate.mjs
bash tests/windows/run.sh
python3 tests/settings-regressions.py
python3 tests/settings-performance.py
bash tests/keyboard/run.sh
bash tests/tabs/run.sh
for folder in Plugins/*; do NOOK_RESOURCES="$PWD" nook validate "$folder"; done
```

- Tab tests: **50** pure navigation/persistence checks and **39** checks using the actual view model/keyboard/shortcut sources with inert services and in-memory preferences. Covers hidden/disabled/missing members, group numbering, wrap/large steps, reordering, JSON, member moves, corrupt preferences, shortcut conflicts, palette hints, direct opens, toggle behavior, and tall-to-short `holdRect` preservation for selection/keyboard/swipes.
- Settings: **49** regression checks and **29** cache/persistence/discovery checks. Windows: **50** geometry/desktop-planning checks plus mocked plugin tests. Store: native client/publisher tests plus **35** JavaScript tests. Agents, Clips, File Search, and all ten keyboard-enabled plugins passed their native/mocked bridge suites. File Search also ran its real read-only Spotlight query/benchmark/filter probes.
- All **15** bundled `Plugins/*` packages validate. Store Word Count validates too.
- Swift harnesses compile in Swift 5 mode with warnings as errors. UI/bridge tests use mocked `window.nook`; new DOM runners and their test-only `jsdom`/`linkedom` packages live under `/tmp`. These packages do not ship in Nook.
- The exact required command succeeds with **zero compiler/linker warnings or errors**:
  `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build`.
  This Xcode host still emits its pre-existing invocation warning, **“Using the first of multiple matching destinations”**, because native/Rosetta/generic Mac destinations match. This is the same host diagnostic recorded in the other agents' reports; it is not hidden or suppressed.
- The explicit universal-destination Release build passes with **zero warnings of any kind and zero errors**, preserving arm64 and x86_64:
  `xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build -destination 'generic/platform=macOS' build`.
- `git diff --check` passes. Logs: `/tmp/nook-tabs-build-exact.log`, `/tmp/nook-tabs-build-universal.log`, `/tmp/nook-tabs-*-final.log`.

Nook was never launched. No GUI automation, typing into apps, user Nook support-data writes, `/Applications` modifications, release/publish scripts, pushes, or merges were performed.

## Lead's manual test

Use only one Nook instance when reviewing the build: quit the existing copy before launching the review copy.

1. In Tabs & Plugins, hide Notes while leaving it enabled. Verify it leaves the dock, numbered navigation, and cycling, but opens with its own hotkey, ⌘K, and `nook://open/notes`. Verify its existing settings/data remain available. Unhide it.
2. Create **Work** with Notes, Files, and Clips; choose a symbol and hotkey. Check the single dock icon, pill switcher, last-member reopening, individual member shortcuts, and active member height. Try a tall-to-short switch with the pointer still at the former dock position: the notch must stay open.
3. Use ⌥⌘←/→ and horizontal swipes to flip members, then ⌃Tab and ⌘[/⌘] to leave the group. Verify ⌘1…9 follows dock order and counts Work once. Repeat after reordering dock items and members in Settings and in the dock.
4. Hide one group member and open it directly. Check its selected pill, and that deck cycling/numbered entry skip it. Hide all members: the dock icon disappears, while member/group shortcuts and the palette remain usable. Disable a member separately and verify it is unavailable until enabled.
5. Expand groups in Settings; drag members and use row menus with the keyboard. Edit membership, move a member to another deck, remove a member from a pair, and delete a group. Verify members return with their visibility preferences intact. Uninstall/reinstall a disposable member and verify saved membership survives.
6. Right-click standalone and group icons; exercise Hide from Dock, Add to Group, and Settings. Verify Settings selects the relevant detail. Check Tab/Return/Esc paths, overflow scrolling, small window sizes, light/dark Settings, and multiple displays.
7. In Keyboard Shortcuts, confirm Open Nook, every window action, groups, tabs, AI commands, dictation, and read-only navigation are present. Try duplicates across categories and reserved navigation. Verify General/Window Management show the same assignments, Reset/clear work, Esc cancels recording, and defaults cannot overwrite conflicts. Try a window shortcut while a notch is key: it should act on the captured external window.
8. Restart the single review instance and verify hidden state, groups, dock/deck order, shortcuts, and last member persist. Confirm keyboard focus, ⌘K plugin actions, drag-to-Shelf, and ordinary notch swipes still work.

## Risks and limits

- Live AppKit/WebKit focus, native drag ordering, context-menu behavior, multi-display interaction, and visual layout still require the manual pass above under the no-launch constraint. Model tests exercise production state logic but cannot prove rendered UI behavior.
- Only one group per plugin; groups are not nested. A group may have one available member temporarily, but creation requires two configured plugins. All-hidden/all-disabled groups are absent from the dock.
- Preferences: `hiddenTabs` is a string array; `tabGroups` is JSON Data; `dockItemOrder` is an array of plugin/group IDs. Existing `tabOrder` remains the base order. No user data migration or deletion occurs.
- Other apps' private shortcuts cannot be enumerated. Plugin action shortcuts remain local to their loaded tab/display and retain the keyboard agent's existing precedence.
- The destination-unspecified build's host warning remains as described above; the universal explicit-destination build is fully warning-free.
