# Migration batch 2 — agent/migrate2

Commands, Agents, Dictation and Mixer now ship as four **default:true v2 Store packages**, with universal
arm64/x86_64 Swift 5 helpers targeting macOS 14.2. Their feature implementations and web UIs are removed from
Nook's compiled sources/bundled Plugins. No new shipped dependencies. Nothing was launched, installed into the
live Nook profile, pushed, merged, published or released.

## What moved

- **Commands:** saved command model/default prompts/editor, expansion, three provider implementations, streaming,
  running/error state, output policy and hotkey/action registration. Selection capture and rich clipboard
  snapshot/restore remain generic host operations. Imported `ai-commands.json` wins over seeding, including
  disabled commands, custom models/prompts, output/copy settings and hotkeys. Fresh starter shortcuts are
  ⌥⌘. / ⌥⌘/ / ⌥⌘;. existing assignments are never replaced with those defaults.
- **Agents:** agent definitions/editor, Codex CLI discovery/exec/resume/process trees, JSONL tool/message cards,
  diff previews, cancellation, session persistence and activity/pinning. Copies `agents.json` and `AgentSessions/`.
  The existing web chat/core/Markdown implementation is retained. Saved chats and large tool snapshots use
  plugin-side chunking (up to 32 MiB per transfer), preserving the engine's 1 MiB frame limit. Full-access behavior and its warning remain.
- **Dictation:** configuration/editor, hold/toggle orchestration, ChatGPT/Groq transcription, cleanup/vocabulary,
  history/audio retention, silent-mic failure/retry, sounds and paste policy. Copies `Dictation/` and all dictation
  defaults, including raw saved hold/toggle shortcut data and selected microphone. Each recording still creates
  a fresh capture session. Recording/transcription activity retains priority over simultaneous Agent/Command
  activities, displays elapsed recording time and a level meter, and restores other ongoing activities afterward.
- **Mixer:** Core Audio device/process discovery, app grouping/icons, preferred-device enforcement, gain/mute
  persistence, tap/rebuild/silence policy and UI. Migrates `audioAppLevels` and preferred input/output UIDs.
  Core Audio capture/render handles stay in Nook for TCC ownership; device preference and mixer policy do not.

All copies are private, staged, reject symlinked roots/contents and leave legacy data untouched. Restarting never
reimports over plugin edits. Dictation history rejects audio paths that are not local WAV basenames. File removal
continues to use Trash semantics. Failed migration refuses startup rather than silently reseeding data.

## Files touched

Packages: `store/plugins/{commands,agents,dictation,mixer}/` (native, UI/editor, manifests, binaries and tests).
Removed: corresponding `Plugins/` folders, `Nook/Services/{Agents,Dictation}/`, AICommands/AudioMixer sources and
Commands/Dictation native panes. New Core files hold generic capture, selection, shortcuts, process cleanup,
activity and migration; `Views/Settings/PluginSettingsPage.swift` renders contributed pages. Shared integration
edits are in Features/Services, PluginEngine/HostAPI/Manifest/Contributions/Permissions/Updates, WebPluginHost,
AppDelegate, NotchKeyboard/ViewModel/RootView and Settings shortcut/navigation integration. Documentation,
Store validators/catalog, generated Xcode project and affected test runners are updated.

## Dictation insertion follow-up

Dictation 2.0.1 inserts one leading space and the transcript at the captured cursor, keeping existing field text.
If a range was selected, insertion occurs at its end. The host retains the real cursor range separately from AI
Commands' select-all fallback and verifies it through Accessibility before pasting. An unsupported/unverifiable
range fails closed; the saved transcript remains visible and copyable. History paste follows the same rule.
The plugin checks `selection.capabilities` first so updating it on an older host cannot trigger unsafe replacement.
A small host migration guard also blocks unsafe paste requests from older Dictation helpers until they update.
The notch button and history paste retain their originating display context; a history paste preserves an ongoing recording's captured target. The clipboard retains the unprefixed transcript. A helper shutdown race found in the engine suite is also fixed:
stdin closure now runs on the same serial queue as pending writes. Manual testing remains necessary on the real Mac and apps.

## What stayed in the host, and why

Generic selection/focus/paste and shortcut models/event tap moved from feature folders into Core. New host files
provide plugin-owned microphone and opaque process-tap handles, value-only activity arbitration, contributed web
Settings pages, and exact-package migration consent. The app's AIBrain is now a thin generic router to the Commands
provider helper; account/login Settings and Codex auth-status parsing remain shared infrastructure.

`contributes.settings[{id,title,entry}]` embeds a local plugin editor in native Settings with the injected kit,
normal bridge gates and lifecycle. Omit entry for the existing native grouped scalar Form. Editors expose the old
controls, model suggestions, shortcuts and explicit deletion confirmation; they save/retry errors inline and flush
pending edits on selection changes. They use web controls inside the native Settings window, not the removed
SwiftUI feature editors. Generic shortcut recording is native.

Host contracts are documented in PLUGINS.md and store/SKILL.md (also mirrored in skill/nook/plugin-v2.md): hold/
release/cancel events, atomic shortcut replacement/recording, selection target capture and append/paste,
microphone PCM-to-WAV capture, audioCapture handles, elapsed/priority activities, AI deltas, Keychain secrets,
folder selection, merged command-palette scopes and explicit helper leases. Capability checks apply to both web
and helper callers. Tab keyboard actions work with the optional Launcher feature disabled.

## TCC findings and design

Apple describes TCC's responsible-code chain as significant for helper access, and notes that the system may fail
to associate a helper with its app. A Terminal-launched test would not prove the signed Nook/helper launch chain's
identity. This branch therefore does **not** rely on inherited child microphone or audio-capture authorization.
See [Apple's helper/responsible-code discussion](https://developer.apple.com/forums/thread/702907).

Microphone authorization checks, requestAccess and AVCaptureSession all execute in the existing signed Nook
process. Apple states that authorization is remembered for the app; an already authorized Nook does not take the
requestAccess path. The helper receives only its private 16 kHz mono PCM16 WAV path, duration and silence peak.
Nook supplies the live level meter without pushing PCM through bounded JSON frames. See
[AVCaptureDevice authorization](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:)).

Likewise, process-tap creation, private aggregate/IOProc and gain rendering execute in Nook. The helper holds only
an owner-scoped opaque handle and owns policy. Apple's tap documentation identifies NSAudioCaptureUsageDescription
and the aggregate-device recording permission prompt. Existing usage descriptions/audio-input entitlement and
Nook signing identity remain. See [Apple's Core Audio tap guide](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

This preserves permission ownership by construction; **no live TCC prompt/capture was exercised** under the
no-launch/no-input rule. The lead must verify the signed single-instance release on the real Mac. Different
signing identities or OS changes can still require OS consent. No TCC database, launch agent or user grant was
changed. Helpers remain unsandboxed trusted code; host capability gates are not an OS sandbox.

## Defaults, trust and idle lifecycle

Existing installations receive these defaults even if the old global defaults-bootstrap flag is already set.
Successful installation is remembered per package, so later explicit uninstall is respected. Existing feature/tab
disables migrate to the plugin owner. On first migration, only SHA-256-pinned first-party packages with matching
verified Store receipts inherit equivalent app-level trust; developer/edited copies use normal consent. Revocation
is never undone. Shared provider credentials migrate read-only from `.secrets` into the host Keychain account
vault; verified Store receipt/content checks prevent a developer copy obtaining them from an ID alone.

Each helper warms once to migrate/register shortcuts. Host-owned hotkeys/actions wake it; hidden unleased helpers
exit after **30 seconds**, retaining registrations. Queued calls/events wait for full helper initialization.
Recording/transcription, active Agent turns and AI requests retain a lease. Mixer stays alive while saved non-unity
levels/mutes or preferred-device enforcement require it; its 5-second reconciliation timer exists only with
non-unity levels. Page eviction preserves leased work. Disable/revoke/crash releases capture and supervised work.
Dictation retention runs on activation/settings changes instead of retaining an idle hourly timer.

Initial Store connectivity is required for these separately delivered packages. They are not bundled back into
Nook; the lead must publish/review the Store packages before distributing the app update. Installed packages work
offline afterward, subject to their provider/network requirements. The first offline launch without installed
packages cannot provide these tools. Custom v1 overrides using removed feature bridges need a v2 migration.

## Size and measurements

Baseline is a86ea85 in the same worktree, same Release command and signing, arm64. Final build followed clean to
exclude stale removed resources. Measurements are for the executable/app; separately delivered helpers add disk
space when installed.

| Measurement | Before | After |
| --- | ---: | ---: |
| Signed app executable (arm64) | 6,824,544 bytes (6.508 MiB) | 5,920,832 bytes (5.647 MiB) |
| Executable reduction | | **903,712 bytes / 13.24%** |
| App bundle allocation (`du -sk`) | 14,564 KiB | 13,544 KiB |

Release universal helpers at the original migration commit b27cfa6, inert host mocks, 3-second settle then ps sample (CPU%, RSS KiB):

| Helper | CPU | RSS |
| --- | ---: | ---: |
| commands | 0.0% | 11,696 KiB |
| agents | 0.0% | 11,664 KiB |
| dictation | 0.0% | 13,440 KiB |
| mixer | 0.0% | 13,024 KiB |

These are warm helper observations, not active recording/AI/routing benchmarks. The actual engine/supervisor test
waits through the real 30-second timeout, observes the helper PID disappear, retains contributions and proves cold
hotkey wake/event delivery. Suspended helpers have no process/RSS. No live app before/after CPU or memory claim is
made: launching this Nook build was forbidden. The lead should compare idle Nook plus WebContent/helper processes
in Activity Monitor after 45 seconds closed, then separately with a running Agent turn or non-unity mixer level.

## Verification

- Required `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build`: **passes with zero errors and zero warnings** (`/tmp/nook-dictation-final-build.log`).
- All four universal helper builds use Swift 5/macOS 14.2 and warnings as errors, with ad-hoc development signatures.
- All four package tests/run.sh suites pass. Commands tests compile actual orchestration/runtime with deterministic
  provider substitutes; Dictation does likewise for transcription. Real stdio RPC uses inert selection, paste,
  microphone and tap host mocks. Tests cover data/shortcut migration, unchanged legacy bytes, edit/restart persistence,
  startup queuing, command output modes/streaming, hold/release/toggle, digital silence/retry, linked-root refusal,
  unknown methods and EOF. Agents tests also load a >1 MiB migrated UTF-8 chat and reassemble
  chunked tool updates. Mixer additionally covers private gain/mute/reset/preferred-input policy without changing
  a real device or tapping audio. Agents retains native Codex mock/process-tree and tool-card/Markdown suites.
- Plugin tab keyboard/empty/error states and all contributed editors run with mocked window.nook under /tmp.
  Shared fixtures live in tests/migrate2; package entry points live adjacent to each plugin.
- tests/engine stays green, including added warmup/Settings/audio capability checks. Store npm tests: 35 pass.
  Shared features, keyboard, tab navigation and 45 Settings regression checks pass.
- The actual engine/supervisor harness also covers leased-page eviction, activity priority/level preservation,
  idle exit, cold wake and disable. No real input/audio API is invoked by this harness.
- Built `nook-cli validate` and Node Store validation pass for **all 10** packages. Symbol/resource inspection finds none of AICommands, AgentService/AgentProcess/AgentsPane, DictationService or AudioMixer in the app, and no bundled copies of the four UIs. `git diff --check` passes.

Logs: `/tmp/nook-migrate2-{final-build,engine-tests,store-tests,demand-tests,idle-measurements}.log`, per-package
`/tmp/nook-migrate2-<id>-{build,tests}.log`, plus keyboard/feature/tab/settings logs. Build final helpers before
regenerating pins/catalog after edits: `python3 tests/migrate2/update-pins.py && node store/scripts/generate-index.mjs`.
Pins must match the reviewed final package bytes; changing package source/tests/binary requires regeneration.

Dictation insertion follow-up verification: the package suite covers original caret and selection ranges, Unicode,
space-prefix behavior, old/new host combinations, saved transcript recovery and originating-notch context. The AI
Commands protocol regression passes; the engine suite passes with queued-write/stop stress. Store tests pass (35).
Logs: `/tmp/nook-dictation-{final-build,insert-tests,commands-regression,engine-final,store-tests}.log`.

## Lead verification on the real Mac

Do not run a second Nook. Quit the installed instance before using the review build. This branch did not install
anything into /Applications or the live support directory. For local developer review, build each package and use
`nook dev "$PWD/store/plugins/<id>" --once`, then enable it. Developer copies deliberately show normal trust consent;
they do not exercise the Store-only silent migration/shared-account path. Configure their own provider secrets or
use verified Store packages to test account migration. Review the catalog/pins and publish Store packages through
the lead's normal process before shipping the app. No publication command was run here.

1. **Upgrade/migration:** with the real existing profile and verified Store packages, confirm all four remain enabled,
   existing command names/order/prompts/hotkeys, agents/sessions, dictation history/mic/cleanup and mixer levels are
   intact. Compare legacy file bytes before/after: writes must go to Data/<id>. Check explicit old disables remain
   off. Revoke one plugin and restart: it must remain disabled, with no helper or retained capture.
2. **Commands:** focus a disposable editor, select text and press ⌥⌘.; verify replacement and clipboard restoration.
   Repeat with only a caret in a populated input: all text must be captured/replaced. Test ⌥⌘/ translation plus copy,
   ⌥⌘; streamed notch output, then custom paste-after and copy-only commands. Try Codex/ChatGPT, Groq and OpenAI,
   provider/model/effort changes, error/retry, editor autosave/duplicate/reorder/delete, native shortcut conflict/Esc,
   Command-K activation with Launcher disabled and two displays. Close the original editor during a request: the
   answer must not paste into another app. Verify existing OS Accessibility permission is reused.
3. **Dictation:** in a disposable editor, type `Hello world` and place the caret after `Hello`. With Nook already
   microphone-authorized, hold the saved gesture (default ⌃⌥), dictate `again` and release; verify `Hello again world`,
   elapsed time/level, cleanup and the unprefixed clipboard transcript. Select existing text and verify a new
   dictation appears after that selection without replacing it. Repeat from a history item's Paste action. Test
   an app with no verifiable Accessibility text range: the transcript must stay visible/copyable in history and
   no text should be replaced. Test app/plugin updates in both orders to confirm old combinations refuse unsafe paste.
   Try saved toggle (default ⌥Space), modifier+another-key cancellation, accidental short hold, two back-to-back
   recordings, mic changes and sleep/wake. Try ChatGPT and Groq, cleanup/vocabulary, disabled shortcuts, history
   copy/paste/remove/retry and unavailable recording errors. Disconnect/choose a silent mic: it must show the
   no-sound failure without pasting invented text. A running Agent/Command must not hide recording activity.
4. **Agents:** open a migrated chat and resume; send a disposable-folder file/listing task. Check streamed tool
   cards, output/diff/code copy, new chat, switcher, stop/⌘., Enter/Shift-Enter/⌘Enter, auto-pin/leave, full-access
   warning/off mode, missing folder/model errors and restart history. Confirm stopping kills local Codex descendants.
5. **Mixer:** play audio in two apps; set one to 50%, mute, boost above 100%, then reset to 100%. Verify gain/mute
   isolation and no capture at unity, default mic/output, preferred-device reconnection, apps beginning/stopping
   audio and output-device changes. Test while a browser records a microphone (no aggregate rebuild/disconnect),
   reused Nook audio-capture permission, denied/silent-tap backoff and disabling/crashing the plugin restoring audio.
6. **Idle/multi-display:** close all plugin/Settings pages and wait 45 seconds. Commands/Dictation/idle Agents should
   have no helper PID; press a shortcut and verify the first event is delivered. No hotkeys survive disabling.
   Mixer may remain for saved levels/preferences. Repeat with two notches and a long recording/Agent turn: evicting
   a hidden page must not interrupt active work, and clearing dictation restores other ongoing activity.

Live focus/clipboard timing, actual provider access, code signing/notarization, mic/device changes and physical
sound routing remain manual verification items. No model calls or GUI automation were used. Development helpers
are ad-hoc signed, not notarized release artifacts. Store trust/integrity and native process sandbox limitations
remain as documented in the v2 engine contract.
