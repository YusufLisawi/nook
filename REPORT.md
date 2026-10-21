# Native notch launcher

Implemented on `agent/launcher`. The feature lives in six new Swift files under `Nook/Services/Launcher/` and reuses the existing notch panel, keyboard/action registries, tab/group navigation and AI Command pipeline. No third-party dependencies or new JavaScript bridge APIs.

## Built

- Borderless 720 pt native search mode that drops from the notch with its existing black shape/spring. Leading glyph, Recent/Results section, cached app icons, title/subtitle/kind rows, soft rounded selection, eight visible rows with scrolling, footer primary action and Actions ⌘K. No dock tab, extra launcher window, focus ring, outline or search border.
- Toggle Launcher uses ⌥Space, falling back to ⌃⌥Space after checking known macOS/Nook conflicts. If both are assigned it starts unassigned. Existing default dictation owns ⌥Space, so the normal fallback is ⌃⌥Space. The shortcut persists after initial resolution, is configurable/disableable in Keyboard Shortcuts and Launcher Settings, and uses the existing Accessibility event tap. Another press closes it.
- Background filesystem app discovery, live Spotlight application-bundle metadata, FSEvents refresh, running-app markers, cached application metadata and lazily rendered 64 px PNG icons. Running applications are available while the first index/cache load completes.
- Search reuses ⌘K's prepared fuzzy matcher with strict prefix > word-start > subsequence > subtitle match classes and bounded, persisted count/last-used frecency. Empty queries show Recent. Optional app:/ai:/plugin:/action:/command: source prefixes. Enabled plugins, hidden dock members, tab groups, AI Commands and loaded plugin actions reuse palette identities.
- Arrow/Ctrl-N/P selection, Return, Command-Return, Command-1–9 result selection, Command-K row actions, Tab Quick AI, and layered Escape (actions/confirmation, chat, text, close). Native text editing remains available. Keyboard visits don't close on pointer movement; outside clicks/resigning key close, and explicit dismissals restore the captured app. Hold rectangles protect shape changes; launcher clicks outside its actual shape dismiss even while an old rectangle is held. CaptureShield applies through the existing panel.
- AI Commands snapshot the external app, clipboard and accessible selection before focus changes, then run through their existing provider/output pipeline. AX work has a short deadline; opaque providers use the existing clipboard fallback after restoring the original app. Replacement checks the original text before pasting, refusing a stale/disappeared target.
- Lock Screen, Sleep, Finder Empty Trash, Toggle Dark Mode, and normal Quit Nook. Sleep/Trash/Quit require explicit inline confirmation. Shell failures stay inline; duplicate execution and late completion are guarded. System commands were not executed in testing.
- Final Ask AI row/Tab hands the literal query to the first saved agent in a new Agents chat, waiting for cold WebKit/plugin loads. With no agent/available Agents tab, an ephemeral native Quick AI chat uses the existing Codex login. Loading, empty and error states are included.
- Grouped Launcher Settings: shared shortcut recorder, source switches, clear recents. History is capped at 500 IDs/counts/dates; no query/selection text is included.

## Files touched

New:

- `Nook/Services/Launcher/{LauncherRanking,LauncherPreferences,LauncherApplicationIndex,LauncherSelection,LauncherFeature,LauncherView}.swift`
- `tests/launcher/{RankingTests,InteractionTests,StateStubs}.swift`, `agents.cjs`, `run.sh`
- `REPORT.md`

Small integration changes:

- `Nook/Core/Services.swift`: startup registration.
- `Nook/AppDelegate.swift`: global launcher shortcut route.
- `Nook/Core/KeyboardActions.swift`: prepared-string overload of the existing fuzzy matcher.
- `Nook/Core/NotchKeyboard.swift`: expose shared entries, transient-mode keyboard/Escape route, avoid focusing hidden web content.
- `Nook/NotchViewModel.swift`: transient-mode dimensions/hooks and plugin lifecycle protection.
- `Nook/NotchController.swift`: outside-click handling and suspend tab swipes during launcher mode.
- `Nook/Views/NotchRootView.swift`: select native launcher content inside the existing shape.
- `Nook/Services/AI/AICommands.swift`: optional captured-context execution.
- `Plugins/agents/main.js`: awaited cold-load-safe native query handoff handler.
- `PLUGINS.md`, `docs/LIMITS.md`: behavior and limitations.
- `Nook.xcodeproj/project.pbxproj`: regenerated project. Regenerate after combining other branches.

## Verification

- Rebased onto main through `4651853` (including the no-focus-ring policy and its guard).
- Required exact `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build`: **BUILD SUCCEEDED, zero compiler/linker warnings or errors** after rebase. Xcode itself emits its existing “Using the first of multiple matching destinations” warning (arm64, x86_64 and Any Mac all match). Log: `/tmp/nook-launcher-build-exact.log`.
- The same build with `-destination 'generic/platform=macOS'`: **BUILD SUCCEEDED, zero warnings of any kind and zero errors**. Full case-insensitive log audit: `/tmp/nook-launcher-build-final.log`. This preserves universal architecture support and does not suppress diagnostics.
- `bash tests/launcher/run.sh`: query/ranking/frecency tests, 500-app optimized filtering benchmark, 43 isolated native interaction checks (including native Quick AI fallback), and mocked `window.nook` agent handoff. Native tests use an in-memory preference store and inert app/selection/shell/agent services; executables and JS run under `/tmp`.
- Measured 500-app filtering in the post-rebase run: 0.887 ms median, 0.981 ms p95, 1.070 ms maximum (<5 ms). Development runs also stayed below 1.7 ms.
- `bash tests/tabs/run.sh`: 50 model and 39 integration checks passed, including the final hit-rectangle/focus changes.
- `bash tests/keyboard/run.sh`: native shortcuts/palette checks and all ten bundled plugin DOM/state checks passed after rebase. Log: `/tmp/nook-launcher-keyboard-final.log`.
- `bash Tests/focus/run.sh`: passed after rebase; no outlines/rings introduced.
- `bash Tests/Agents/run.sh`: all native/process, plugin state and shipped DOM tests passed.
- `NOOK_RESOURCES="$PWD" nook validate "$PWD/Plugins/agents"`: passed.
- `git diff --check`: passed.

## Lead's manual review

Quit the currently running Nook before running this branch's build; only one instance should run.

1. From a text editor with selected text, toggle ⌥Space. Confirm the input receives typing immediately, the notch opens with no border/ring, and pointer movement doesn't close it. Measure first-frame latency (<50 ms target); real AX/SwiftUI presentation cannot be validated without running Nook.
2. Search an installed app, an already-running app, partial/diacritic names, an AI Command, hidden plugin, tab group and a registered action. Test ↑↓, Ctrl-N/P, Return, Command-Return, Command-1–9, Command-K, Tab, clear-then-close Escape, toggle close and outside clicks. Confirm focus returns to the editor, and try multiple displays/full screen.
3. Run Rewrite on the captured selection. Confirm the launcher query never becomes input, clipboard placeholders use the pre-launch clipboard, replacement targets the original input, and stale/disappeared targets fail rather than overwriting edited text. Try an editor with weak AX support to exercise the existing fallback.
4. Test app launch/reveal and plugin/tab/action alternate behavior. Check recents reorder after use, survive restart, clear in Settings, and respect source switches. Change/disable the launcher shortcut and test a duplicate assignment in Keyboard Shortcuts.
5. With Agents cold/unloaded, ask a query using Tab; confirm the first saved agent opens a new chat with that exact text. Test agent error and native Quick AI fallback when no agent exists/Agents is disabled. Escape backs out; Copy Answer works.
6. Intentionally exercise System commands on a disposable desktop session. Trash/Sleep/Quit require the second activation and Esc cancels; Finder/System Events may request Automation permission. Quit should restore proxy/audio through normal shutdown.

## Risks and limits

- Nook was never launched; no GUI automation or typing into apps was used. No `/Applications` changes, live `~/Library/Application Support/Nook` writes, release/publish scripts, pushes or merges were performed.
- First-frame latency, real AppKit key focus/return, AX selection fallback/paste, FSEvents/Spotlight changes, multi-display/fullscreen presentation and visual layout still need the manual review above. Automated tests intentionally do not post events, launch apps, empty Trash, lock or sleep the Mac.
- The exact destination-unspecified build retains Xcode's environment destination warning described above; the explicit generic-destination build is warning-free.
- Other applications' private hotkeys (including Raycast's) cannot be discovered. Spotlight Privacy and mounted-volume availability limit discovery. Nook app bundles are omitted to avoid launching a competing copy. The app/icon cache is disposable and intentionally independent of user plugin data.
- Accessible selection is captured before focus; opaque AX providers use the captured external app plus the existing selection fallback after dismissal. An unresponsive provider can decline the snapshot. Changed/closed source inputs may prevent replacement.
- Plugin actions are scoped to the display and appear once loaded. Agents uses the first saved agent; native Quick AI uses Codex and doesn't persist a separate conversation. Network/model/CLI access is inherited from existing AI services.
