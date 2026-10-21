# Window management — agent/windows

Implemented the 23 requested window actions, a native **Window Management** Settings pane, and the bundled **Windows** notch plugin (order 48, height 260). Continued and audited the partial implementation already in this worktree.

## Behavior

- Halves, quarters, thirds/two-thirds, Maximize, Almost Maximize, Maximize Height/Width, Center, Restore, Previous/Next Display, and Previous/Next Desktop.
- Accessibility targets the frontmost app's focused AX window. Each notch captures its own exact window before opening; switching tabs or focusing the web view cannot retarget it. Separate pinned notches retain separate captures.
- Layouts use each display's usable frame, converting AppKit coordinates to Quartz points, including displays above/left of the primary display. Display moves wrap left-to-right, then top-to-bottom, preserving relative frame fractions and fitting the destination.
- Almost Maximize defaults to 90%, adjustable in native Settings. Restore preserves the frame before a sequence of Nook layouts/display moves. Manual movement starts a new sequence. History is in memory, bounded to 64 windows; Restore does not restore desktop membership.
- Shortcuts default to **unassigned**, persist in UserDefaults, and use the existing event tap. Recorders warn/block conflicts with other Nook window actions, tabs, enabled AI Commands, dictation shortcuts and known/enabled macOS shortcuts. Other apps' global shortcuts cannot be enumerated. Using ⌃⌥ plus a key cancels the default dictation hold.
- Plugin: search, two-column action grid with shortcut labels, arrows/Tab, Enter/⌘Enter, Esc, loading/empty/error states, configurable close-after-action, and Accessibility/Settings links. Refreshes preserve grid focus and discard stale state replies.

## Desktop moves: approach and limits

Use a title-bar drag plus the user's configured Mission Control left/right Space shortcut. Read-only SkyLight/AX symbols discover the current desktop, reject invalid destinations, and verify final window membership. Symbols are resolved dynamically; their absence produces an explanatory error. There are no private Space mutations, injected helpers, SIP changes, new dependencies, or edits to macOS keyboard preferences.

Moves close all notches, wait for shortcut release, activate/raise the captured window, confirm focus and a safe title-bar hit, start a small drag, verify that the window moved, hold through the desktop transition, release, verify membership, and restore the pointer when the user has not moved it. Cleanup releases a held drag on errors/cancellation. Desktop moves follow the window; they do not wrap or create desktops. Failures remain readable on the next plugin open and briefly show a closed-notch error activity.

Requires ordinary desktops and a movable window with an accessible draggable title bar. Full screen, Split View, All Desktops assignments, disabled/intercepted Mission Control shortcuts, custom title bars, spanning/tiled windows, pointer movement, or changed macOS behavior can prevent movement. A failed transition can change the visible desktop without moving the window; the error directs the user to Mission Control. Unsupported cases do not fall back to clicking arbitrary controls. Stage Manager's app strip is not separately reserved. App minimum sizes can constrain layouts; a partially applied layout retains a Restore frame.

Research, read with browser-bridge:

- [Raycast Window Management manual](https://manual.raycast.com/window-management): command names and focused-window, display, Space, sizing, and shortcut behavior. The requested subset is implemented; Nook's Almost Maximize percentage and Restore-series behavior are explicit choices documented above. No Raycast code/assets were copied.
- [Amethyst PR #1698](https://github.com/ianyh/Amethyst/pull/1698): restored grab-and-shortcut Space moves and subsequently respected symbolic hotkey customizations. Its discussion also records multi-display/title-bar fragility.
- [Rectangle's Space limitation](https://github.com/rxhanson/Rectangle#rectangle-doesnt-have-the-ability-to-move-to-other-desktopsspaces): no public Space API; open-source Rectangle does not offer these actions.
- [yabai SIP documentation](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection): privileged Dock injection is a distinct approach with system-security requirements unsuitable here.
- [Apple's macOS 26 Spaces guide](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/26/mac/26): desktop switching, moving windows, and All Desktops assignments.

**macOS 26 runtime compatibility needs hands-on validation by the lead.** The chosen implementation avoids SIP changes and validates each step, but is not claimed to work for every app. Nook was never launched and no app-window GUI automation was executed during this task.

## Files

New feature files in `Nook/Services/Windows/`:

- `WindowActions.swift`: commands and pure display/layout geometry.
- `WindowAccessibility.swift`: AX target capture, frame operations and title-bar hit testing.
- `WindowSpaces.swift`, `WindowDesktopPlan.swift`: read-only Space discovery, validated adjacent-desktop planning, drag/shortcut execution.
- `WindowTargets.swift`: bounded, per-notch captures.
- `WindowManager.swift`: orchestration, Restore history, bridge and Settings registration, error reporting.
- `WindowShortcuts.swift`, `WindowManagementPane.swift`: persistence/conflicts and grouped native shortcut UI.

Also added `Plugins/windows/{plugin.json,index.html,main.js,style.css}` and offline checks under `tests/windows/`.

Minimal shared edits:

| File | Change |
| --- | --- |
| `Nook/Core/Services.swift` | Start/register WindowManager before plugins load. |
| `Nook/AppDelegate.swift` | Shortcut-chain handler and close-notches callback. |
| `Nook/NotchViewModel.swift` | Capture before a closed notch opens. |
| `Nook/Core/WebPluginHost.swift` | Bind the registered windows bridge to its host notch's capture. |
| `Nook/Services/Dictation/HotkeyMonitor.swift` | Swallow matching shortcut key-ups/repeats as well as key-downs. |
| `PLUGINS.md`, `docs/LIMITS.md` | Bridge contract and capabilities/limits. |
| `project.yml`, generated `Nook.xcodeproj/project.pbxproj` | New Swift files; skip unused App Intents metadata extraction to avoid its empty-metadata warning. |

## Verification

Run from the repository root:

```sh
bash tests/windows/run.sh
nook validate Plugins/windows
xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build
```

The requested invocation succeeds with zero compiler/linker warnings. On this Apple Silicon host, Xcode 26.0.1 emits one destination-selection warning because it matches both native and Rosetta destinations. Use an explicit generic Mac destination for a deterministic universal build with no destination ambiguity:

```sh
xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build -destination 'generic/platform=macOS' build
```

The explicit-destination Release build passed with **zero errors and zero warnings** and produced a universal arm64/x86_64 binary. Plugin validation, all offline checks, and `git diff --check` passed. No supported architectures were removed to suppress the destination warning.

The offline Swift checks use Swift 5 and warnings-as-errors: 50 checks cover coordinate conversion, odd-width tiling, relative display transfers, usable bounds, desktop boundaries/full-screen/sticky-window refusal, and per-notch capture isolation/lifetime. Plugin tests execute a copy under `/tmp` with mocked `window.nook` and DOM, covering loading/empty/error/ready, search, arrows, Enter/⌘Enter/Esc, focus retention, busy-state recovery, stale replies, preferences and failures. No tests post native input events or instantiate app services against real Nook data.

## Lead's manual test checklist

Use a single Nook instance under your control when evaluating this branch; do not start a second copy beside the user's running app.

1. Grant Accessibility, open Window Management Settings, record/clear shortcuts, try a duplicate and a macOS shortcut, then switch focus away while recording. Verify recording releases the event tap. Reopen Settings to verify persistence.
2. Focus a resizable app window, open Windows, navigate with arrows/Tab, apply halves/quarters/thirds and sizing/centering. Apply several layouts then Restore. Manually move the window and repeat. Try a small fixed-size window and a closed target to inspect errors.
3. With two differently sized displays, exercise Previous/Next Display, including a display positioned above/left. Verify relative frame scaling, menu bar/Dock clearance, wrapping, and Restore after a display disconnect.
4. Pin a notch for one app window; focus a different window and open the notch on another display. Each notch must keep its own target.
5. On macOS 26 with two ordinary desktops, enable Mission Control's Move left/right a space shortcuts. Focus a standard title-bar window; apply Next/Previous Desktop through the plugin and through an assigned global shortcut. Release modifiers promptly and leave the pointer still. Verify window membership, follow behavior, retained frame and pointer restoration. Repeat on each display and with customized Space shortcuts.
6. Try first/last desktop, a neighboring full-screen Space, All Desktops assignment, disabled Space shortcut, custom title bar and pointer interruption. Verify a useful failure and no held mouse button. Reopen Windows after an error to read its reason.

No writes to `/Applications` or the user's Nook support data, no release/publish scripts, and no push/merge/publication were performed.
