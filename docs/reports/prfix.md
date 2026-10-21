# PR #1 and #2 integration

Integrated outside contributor smouad / Mouad Sodor's PRs into `agent/prfix`, preserving his original commits and authorship.

## History

- Fetched `pull/1/head:pr-1` and `pull/2/head:pr-2` from origin.
- PR #1 original commit: `8dfae7c6979c6106ff5c20b610c9a60995d3d4e9`; merge commit `1e568e1`.
- PR #2 original commit: `6c9951df236d5f0aeb9aecf33e257890cc881809`; merge commit `da93d39`.
- Fixes are subsequent commits, with no squash or rewrite of contributor history.
- Merged latest local main (`3ea59b0`, Nook 1.6.5) in `e30e662`. Double-click pinning and fresh dictation capture sessions are retained.

## Result

PR #1 keeps the fixed notch-shaped clipping and immediate, nonanimated content removal on close. Hover opens retain the contributor's 180 ms delayed attachment; keyboard entry bypasses it, including entry while a hover reveal is pending. Close/reopen cannot let stale cleanup remove the newly opened content. Main's LauncherView/ExpandedView branch and `!launcherPresented` open-event guard remain.

Initial native focus follows content attachment. Early typing is buffered until focus is ready, including launcher/palette entry, and discarded when the notch closes. Stale web-focus completions cannot release input into a newer focus request. The header search button still crossfades with the spring; typing still uses main's instant launcher resize.

PR #2 remains a normal Mouse web plugin, off by default. Suppressed physical buttons are tracked independently. Disabling/finishing learning cancels actions and scrolling, restores the pointer, and retains the tap until all swallowed releases are handled. Overlapping gestures cancel the older action while preserving its release. Learning claims one result on the tap thread.

Mouse-generated keys bypass both global HotkeyMonitor and local notch shortcuts without changing dictation state. Opposite-direction wheel ticks are preserved by default; optional `filterChatter` is off for existing and new preferences. A reversal also clears the old axis's fractional scroll carry. Tap failures appear as inline errors and retry every two seconds while enabled/learning, including permission changes. App Nap suppression is held only during scroll animation.

The mouse bridge uses BridgeRegistry, with no Mouse-specific switches left in WebPluginHost and no native Settings pane. The plugin adds accessible control names, arrow navigation, Command-Enter actions, retained focus when editing rules, startup/retry/error states, and cancellation of learning on close. Existing dock navigation and its 12-item cap are unchanged.

## Files touched

- Contributor files: `Nook/Services/MouseFix/{MouseActions,MouseConfig,MouseFixService,MouseScroller}.swift`, `Plugins/mouse/*`, `README.md`, `site/index.html`, `skill/nook/SKILL.md`, `PLUGINS.md`, and the two notch view/model files.
- New native helpers: `Nook/Services/MouseFix/{MouseBridge,MouseEventState}.swift`, `Nook/Core/SyntheticInput.swift`.
- Integration/focus fixes: `Nook/Core/{Services,WebPluginHost,NotchKeyboard}.swift`, `Nook/NotchViewModel.swift`, `Nook/Views/{NotchRootView,KeyboardPalette}.swift`, `Nook/Services/Launcher/LauncherView.swift`, `Nook/Services/Dictation/HotkeyMonitor.swift`.
- Tests: new `tests/mouse/{NativeTests.swift,Stubs.swift,plugin.cjs,run.sh}`, extended `tests/launcher/InteractionTests.swift`, and source-list updates in keyboard/launcher/tabs test runners.
- Documentation: `PLUGINS.md`, `docs/LIMITS.md`, this report. Xcode project regenerated with xcodegen.
- Latest-main merge also carries its version/appcast changes and `NookUI/nook-keyboard.js` double-click handler.

## Verification

All automated checks run without launching Nook or installing a live event tap:

- `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build`: Release build succeeds with **zero warnings and zero errors**.
- `bash tests/mouse/run.sh`: 7,000 native checks covering all down/up orderings of four overlapping buttons, learning/disable drain, reenabling, both wheel axes/directions, chatter opt-in, preference migration, and actual HotkeyMonitor processing of in-memory synthetic events. No events posted. Mocked `window.nook` plugin checks execute under `/tmp` using jsdom.
- `bash tests/launcher/run.sh`: ranking/performance, 51 launcher/lifecycle checks, agent handoff.
- `bash tests/keyboard/run.sh`: native shortcuts, shared arrow/Tab/Enter/alternate navigation, bundled plugin mocked-bridge and error/empty-state checks.
- `bash tests/tabs/run.sh`: 50 navigation/model checks and 39 shortcut/deck integration checks.
- `bash tests/focus/run.sh`: no focus rings.
- `nook validate Plugins/mouse`: passes.
- `git diff --check`: passes. Both PR tips and latest merged main are ancestors of this branch.

No runtime dependencies were added. Tests use the existing repository convention of installing jsdom 26.1.0 into a temporary directory only.

## Lead's manual checks

Use one Nook instance; these checks were intentionally not automated or performed against the user's running copy.

1. Open/close web and native tabs repeatedly, including a fast close/reopen and multiple displays. Verify no header/dock/web-content ghosts. Hover should reveal after the shape grows.
2. Open the launcher by shortcut and type immediately; repeat from the header search button. Verify the first characters arrive, the opening crossfades/springs, and query-driven height changes snap. Open a native tab by keyboard and type immediately into its initial control. Also try Command-K during entry and Escape/rapid tab changes.
3. Double-click empty native and plugin space to pin/unpin. Controls/text inputs should retain their normal double-click behavior. Confirm dictation still starts with a fresh capture session.
4. With Mouse disabled, choose Add a button, press and keep holding an extra button, then release. Repeat with overlapping buttons. Configure click/hold/drag mappings, overlap several buttons and release in different orders, and disable while held. Verify no stray release reaches the target app and the pointer is restored.
5. Assign a Nook shortcut that overlaps a generated mouse action (for example Command-C); the mouse action must reach the focused app once without opening Nook or affecting dictation.
6. Spin a wheel up/down rapidly: reversals should work with chatter filtering off. Opt in only for a wheel with real chatter. Check horizontal/precise/quick modifiers and continuous trackpad pass-through.
7. Deny/revoke and grant Accessibility while enabled/learning. Verify actionable errors and automatic recovery rather than an indefinite Starting status. Check idle energy use versus active smoothing.

## Limits and risks

Actual event-tap/hardware, keyboard first-responder timing, visual ghosting, App Nap behavior, and permission transitions need the manual checks above, especially on macOS 14/15 and multiple mouse models. Automated native tests create events in memory only.

Settings are global, not per app/device. An overlapping gesture cancels the prior gesture's action. macOS permission revocation, termination, or unplugging hardware can interrupt release delivery; normal disable/learning teardown drains releases while delivery remains available. Mission Control/Spaces/media actions depend on macOS shortcuts and target-app support.

No Nook launch, GUI automation, writes to /Applications or the user's Nook Application Support data, push, GitHub comment/merge/close, or release/publish operation was performed.
