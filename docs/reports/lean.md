# Lean features and idle efficiency — agent/lean

Implemented a central lifecycle registry and Settings → Features, plus the idle-work audit. This branch never launches Nook.

## Behavior

- `FeatureLifecycle` is the small, testable start/stop engine; `Features` supplies the native catalog and extension-point registrations. Factories capture no optional service instances. `Services` allocates optional services on demand and releases their slots on stop.
- Launcher, Smart Answers, Launcher File Source, File Search, Clipboard History, Screenshots & Recordings, Window Management and Mouse default **off**. The one-time migration runs before startup on the next launch, including an existing user's installation. Other existing tab enable choices are preserved. I did **not** modify the running user's preferences/support data to apply it early.
- Features owns native service, bridge, settings and shortcut lifetimes. Tabs & Plugins uses the same state. Disabled tabs leave dock/navigation/palette/launcher sources, loaded views and shortcut routing. The launcher header search button hides. Shortcut assignments, plugin groups, history and user files remain saved.
- Clipboard/screenshot collection is independent, sharing Clips only while at least one owner is enabled. Capture settings can be opened without enabling clipboard/file indexing. Native File Search, launcher and answer caches are released on stop, including C cursors and the large location table.
- Dictation and the global shortcut tap have separate lifetimes. Disabled Dictation reserves neither default gesture. Mixer removes Core Audio listeners/taps and skips idle process polling unless saved volume enforcement needs it. Window Management releases AX targets, Restore history and lazy private-framework handles. Agents, Cleaner and Store cancel owned work on disable. Proxy cleanup drains before closing the forwarder.
- No 30 Hz per-display hover timer: mouse/workspace events drive it, and `ignoresMouseEvents` changes only when needed. Fullscreen-hidden panels detach collapsed animations. Media has no timer without Music/Spotify; otherwise polls at 5 s, avoids duplicate paused updates, cancels artwork downloads and coalesces work. Clipboard/Links poll at 2 s with tolerance. Active timers tick at 1 s.
- Web views remain lazy; hidden ones unload after 15 s, disabled ones immediately. Page-owned shell process trees, HTTP/AI requests and action registrations are cancelled on unload. Monitor/Home/Mixer stop their intervals immediately on hide, and Home respects disabled stats/timer capabilities. Closing Settings releases the hosted pane and its timers; startup no longer prewarms it.
- No new shipped dependencies. Test-only jsdom installs stay under `/tmp`.

## Measurements

Read-only observations of the **already-running installed app**, PID 91568, macOS 26.5.2, October 21, 2026. No windows were opened or input posted. This is an uncontrolled idle observation, not a comparative benchmark.

| Metric | Installed app, before | Built branch, after |
| --- | --- | --- |
| CPU, one core | `top`: 8.7%; calibrated 5.003 s rusage probe: **7.783%** | Not measured — Nook was never launched |
| Interrupt wakeups/s | **67.965** | Not measured |
| Package idle wakeups/s | **0.200** | Not measured |
| Physical footprint | `sample`: **142.2 MiB**, peak **171.4 MiB**; later rusage **146.64 MiB** | Not measured |

The sample contains `NotchController.tick → setIgnoresMouseEvents → WindowServer/Core Animation transaction` and repeated drag-pasteboard checks, plus Launcher Spotlight updates. Removing the idle timer also removes its 30 scheduled callbacks per second **per display** and its once-per-second fullscreen probe. Default-off indexes and provider-owned tables remove their retained allocations. These are code-level reductions; actual CPU/footprint gains are deliberately not invented.

`scripts/measure-idle.sh` accepts only the built review binary's PID. The lead must first quit the installed copy and manually launch the review copy, close the notch, let it settle 30 s, then run:

```sh
scripts/measure-idle.sh PID 30 /tmp/nook-lean-after
```

It never launches/activates anything or uses sudo. CPU converts Mach ticks with the host timebase (validated against a 1 s process CPU-clock loop). It captures CPU/wakeup deltas before perturbing the app with top/footprint/sample. Sampling records timer stacks observed, not an exact registered-timer count. The helper compiled with `-Wall -Wextra -Werror`; the script's refusal of the installed app was tested. `powermetrics` was skipped because this host requires privileged sampling.

Raw before artifacts remain at `/tmp/nook-lean-installed.sample.txt`, `/tmp/nook-lean-installed.top.txt`, `/tmp/nook-lean-installed.footprint.txt`, and `/tmp/nook-lean-installed-corrected.metrics.json`.

## Files

New files: `Nook/Core/{FeatureLifecycle,Features,FeatureVisibility,PluginWork}.swift`, `Nook/Views/CaptureFeatureSettings.swift`, `tests/features/*`, and `scripts/measure-idle.sh`.

Integration edits span `Services`, extension/shortcut/plugin registries, AppDelegate, notch/controller/view model, Settings, web hosting and optional services. They are lifecycle/gating/teardown edits in their owning files; private resources cannot be correctly stopped by an external extension alone. This necessary breadth is the principal merge risk with the other engineers. No unrelated feature/UI redesign, release configuration, new dependency or release script changes.

Also updated Home/Mixer/Monitor polling, documentation, generated Xcode project and existing isolated harness stubs for the shared hotkey API. The old Settings regression assumed exactly four native tabs; its multi-row move expectation now preserves additional native tabs.

## Verification

- The exact required `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build` passes with **zero errors and zero warnings**, including invocation diagnostics. No architectures were removed and no warnings were suppressed.
- `tests/features/run.sh`: **25** lifecycle/default/migration/resource checks with fakes and weak ownership, the real inert hotkey monitor, production bridge-work/process-tree cancellation, and mocked Home/Monitor/Mixer visibility/capability checks. No native input event is posted.
- Existing suites passed: Agents (native + mocked DOM/process tree), Clips (capture/privacy/models, real /tmp folder watcher/OCR and mocked DOM), File Search (index/query/Spotlight/preview/access/real FSEvents + mocked DOM), Windows (**50** geometry/planning checks + mocked DOM), Launcher (**500** apps ranking, **24** interaction checks + mocked agent handoff), Answers (**12,221** provider checks + deadline/currency cache suites), Tabs (**50** model + **39** integration checks), Keyboard (native + all shipped keyboard-enabled plugin DOM), Store (native client/publisher with mocked gh), Cleaner (fake-home/native/mocked DOM), Settings (**49** regression + **29** performance/discovery checks).
- File Search's watcher suite now also proves `stop()` clears ready/count/configuration state, repeated stop is safe and re-enable restores/catches up. Bridge cancellation tests run only a test-owned sleep process under `/tmp` and verify no shell survives teardown.
- All **16** bundled plugins validate. `bash -n scripts/measure-idle.sh` and `git diff --check` pass. Swift harnesses use Swift 5/macOS 14.2 and warnings as errors. The test-only jsdom transitive dependency emits an npm deprecation notice; it does not ship in the app or affect the warning-free Release build.
- Final build log: `/tmp/nook-lean-build-verified.log`; test logs: `/tmp/nook-lean-*.log`. Full native/UI/permission and after-build performance measurements remain the manual review below, under the no-launch constraint.

## Lead review

1. Quit the existing instance before starting the review build. Confirm first-launch migration: clone switches off, search button absent, clone tabs/panes/shortcuts absent. AI Commands/Agents/Dictation/Links/Notes/Timers/Shelf/Mixer/Monitor/Proxy retain their existing enabled choices.
2. Toggle each feature twice, both in Features and Tabs & Plugins. Check instant removal of its tab/current content, native pane/rows and shortcuts; re-enable and verify saved preferences/shortcut values return. Check each half of Clips independently. Enable Launcher and Smart Answers/File Source separately and verify dependency behavior.
3. With clone features off, verify typing Option-Space does not trigger/swallow Nook's disabled launcher/dictation assignment. Turn Dictation and Keyboard off too: remaining assigned tab/command/window shortcuts should determine whether the shared tap exists. Permission recorders must still work for enabled owners.
4. Enable File Search, wait for indexing, disable while indexing/searching/previewing, and re-enable. Verify no FSEvents/Spotlight work or packed index remains after teardown; searches and catch-up resume. Exercise multiple displays and user web overrides.
5. Start an agent and dictation, then disable their features; verify cancellation and recoverable saved history. Disable Mixer with a non-default app volume and verify original audio returns. Disable an active Proxy and verify system connectivity. Disable Cleaner while it measures a test fixture: no further Trash moves should start.
6. Open and leave Monitor, Home and Mixer; close the notch, wait 15 s, and verify WebContent memory is released. Reopen and check saved data. Verify no Store network request until opened. Close Settings while Store is selected and verify its refresh timer stops.
7. Review hover/click/drag-to-Shelf, pinning, keyboard focus, Escape, active-space/fullscreen transitions, capture shielding and multi-display behavior. Animations and AppleScript/AX behavior need this manual pass; no GUI automation was used.
8. Measure idle with the script, then repeat with all optional features off and selected features individually on. Record these after numbers before merging.

## Risks and limits

- OS filesystem/AppleScript calls already executing can finish their current call while cancellation drains. Packed scans check cancellation between entries. No further disabled feature result is published; native runtime/allocator caches can keep high-water pages after app references are freed.
- Unloading web views resets ephemeral page state; plugins must save drafts/state. Native agent turns and running countdowns survive ordinary tab hiding while their feature remains enabled. Plugin scripts that intentionally daemonize outside their process tree cannot be reliably reclaimed.
- Two-second clipboard/link capture can miss copies replaced inside that interval; 5-second media polling can delay transport updates. Timer values remain date-based, so the lower display tick does not change elapsed-time accuracy.
- Core notch/pointer handling, manifest hot-reload, Settings, saved descriptors and the shared shortcut infrastructure remain app infrastructure. Off means no optional service work/cache ownership, not that the whole process or OS frameworks occupy zero bytes.
- The migration is intentionally pending until the lead runs this branch. No modifications to `/Applications` or the user's `~/Library/Application Support/Nook`, no Nook launch, no GUI automation/input posting, no push/merge/publication, and no release/publish scripts.
