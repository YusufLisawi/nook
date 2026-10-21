# Migration batch 1 — agent/migrate1

Four default-off v2 packages now live in `store/plugins/{file-search,clips,windows,launcher}`. Each includes a
universal arm64/x86_64 Swift helper, local vanilla-JS UI, declarative Settings and adjacent tests. The catalog marks
all four `default:false`; first discovery explicitly leaves them disabled. Nothing is preinstalled/enabled for Raycast users.

## What moved

| Package | Ownership moved out of Nook |
| --- | --- |
| file-search | C filename matcher, packed index/cache, query compiler/ranking/frecency, FSEvents, protected-path policy, Spotlight fallback, previews/Quick Look, file actions and tab UI |
| clips | Clipboard capture/privacy markers/ignored apps, private images/history/retention, capture-folder watcher, recording/screenshot index, Vision OCR, rich Copy/Paste, pins and Trash |
| windows | AX window identity/geometry, 23 actions, display transforms, Restore history, desktop membership/drag logic, saved shortcuts and UI |
| launcher | App discovery/Spotlight/FSEvents/cache, ranking/history/source preferences, system commands, Quick AI orchestration, all seven answer providers, provider discovery and places.tsv |

The File Search helper contributes files from its **single existing index**. Launcher does not duplicate that index.
The File Search “Include files in Launcher” choice also imports the old launcher source preference.

Feature source directories and native Settings views were removed from `Nook/`; bundled Files/Clips/Windows packages
were removed from `Plugins/`. `project.yml` no longer compiles/bridges the C matcher. The generated Xcode project was
updated. Symbol inspection of the Release app finds none of FileNameIndex, ClipboardHistory, ScreenCaptureIndex,
WindowManager, LauncherApplicationIndex, MathAnswerProvider or nf_search. The app resource bundle has no places.tsv
or removed bundled feature UIs.

## What stayed and why

Core retains generic native search presentation, focus/keyboard routing, notch sizing, bounded asynchronous provider
coordination and value-only answer models/cache. SwiftUI remains responsible for the native notch transition and text
field; no application/file discovery, ranking, answer implementation or place table remains in that renderer.
`AICommandContext` moved to Core as the already-shared selection/AI host primitive. System shortcut conflict detection
also remains generic host infrastructure. Settings panes use the engine's existing grouped SwiftUI Form.

New generic host contracts, documented in PLUGINS.md and store/SKILL.md (also mirrored in the repo's v2 skill):

- `contributes.searchProviders` with query/action methods, requires `launcher` and a native helper. Queries provide the
  current Nook item catalog; helpers return ordinary item/answer values. Activation can return an answer or an existing
  host item ID. Prefix answer-provider contributions remain supported.
- `host.launcher.open`, gated by `launcher`; Launcher shortcuts use host v2 hotkeys.
- `host.files.scopes`, gated by `files`, returns approved roots without requesting TCC.
- `shortcut` setting type, gated by `hotkeys`, renders the existing native recorder. Users never edit shortcut JSON.
- Approved Windows+Accessibility helpers receive opaque per-notch `beforeOpen` identity. Native RPC includes the
  originating notch's reserved `__context`; hotkey events include a context only for an actual focused notch panel.
  Window actions/Space heuristics stay entirely in the helper. Missing identities fail closed.

Query requests coalesce to one running/one latest replacement per provider/display, with stale generations discarded.
Disabling removes providers/hotkeys and terminates the helper; consumer changes no longer accidentally remove an
unrelated helper's global shortcuts. No polling/index/cache/table is created for an uninstalled or disabled package.

## Files touched

New packages: `store/plugins/{file-search,clips,windows,launcher}/` (UI, helpers, build scripts, metadata and tests).
New host files: `Nook/Core/PluginSearchMode.swift`, `SelectionContext.swift`, `SystemShortcutConflicts.swift`,
`PluginEngine/PluginSearch*.swift`, `PluginWindowIdentity.swift`, and `Views/Settings/PluginShortcutSetting.swift`.
Shared edits remove old registrations/routes and add generic contracts in Features, PluginRegistry, PluginEngine/
Contributions/HostAPI/Manifest, PluginSettings/Form, NativeShortcutIntegration, NotchKeyboard, AppDelegate,
NotchViewModel, WebPluginHost and NotchRootView. Tooling/docs edits cover project.yml/generated project, CLI setting
validation, Store validators/catalog, PLUGINS.md, LIMITS.md, builder skill, regression runners and this report.

## Migration and privacy

First helper run imports matching old defaults into a private `NOOK_DATA_DIR/preferences.plist` and synchronizes the
plugin Settings form. File/app/currency caches are copied into the plugin data directory. File cache fingerprints
include scope/exclusions/cache location, so a first safe rebuild can be necessary despite copying the old cache.

Clips copies the legacy Clips directory, preserves IDs/pins/OCR data, and rewrites only owned image paths in the private
history copy. Screenshot/file references remain references to originals. Migration rejects symlinked cache roots or
contents before copying, stages directory copies, and never replaces an existing plugin directory or later edits.
Legacy defaults/files are read-only. Directory/file permissions are private. Tests prove image/path/pin preservation,
restart persistence, concurrent preference writes and idempotence against generated /tmp fixtures.

Old app folder grants are not replayed as helper authorization. File Search uses its lexical protected-folder policy;
Clips checks its approved lexical root **before any path inspection**, then refuses symlink components. Screen indexing
needs an approved capture folder and does not start when disabled/denied. All user-file deletes use Trash semantics.
Replayed clips carry the transient pasteboard marker so other plugin processes skip them.
Clips UI history is paged below the 1 MiB transport limit; previews use bounded text/OCR/path snippets while native
Copy/Paste and saved history retain full content.

## Size and timings

Same host Release configuration, baseline c48b219 versus this branch; app was never launched:

| Measurement | Before | After |
| --- | ---: | ---: |
| Signed app executable, arm64 | 9,039,648 bytes (8.621 MiB) | 6,824,544 bytes (6.508 MiB) |
| Executable reduction | | **2,215,104 bytes / 24.50%** |
| App bundle disk allocation (`du -sk`) | 19,844 KiB | 14,548 KiB |

The final build followed a clean to avoid counting stale removed resources. Store helpers/data are delivered separately;
these figures do not pretend that installing/enabling all helpers has no disk or process cost. No running-app CPU or
memory improvement is claimed under the no-launch constraint.

Repeated native matcher benchmark, optimized C/Swift, read-only home scan with protected/cloud/media/mount exclusions:

- 181,845 names: scan **4.752 s**, allocated index **56 MiB**, process peak RSS **86.69 MiB**.
- Home query medians **0.979–3.204 ms**, p95 **1.005–3.272 ms** across the existing benchmark query set.
- Cache save **0.064 s**, restore **0.102 s**, 34,291,446 bytes.
- Synthetic 1,000,000 names: build **1.055 s**, allocated index **176 MiB**; query medians **2.831–5.808 ms**,
  p95 **2.938–5.929 ms**. These exclude IPC/rendering. Incremental candidate copying can take 6–15 ms on that fixture.
- Launcher 500-app ranking stays sub-millisecond median in the retained ranking suite; provider checks retain their
  2 ms cooperative budget. Timings are observations on this host, not cross-machine performance guarantees.

Raw logs: `/tmp/nook-migrate1-{final-build,files-tests,clips-tests,windows-tests,launcher-tests,engine-tests,store-tests}.log`
and `/tmp/nook-migrate1-files-{benchmark,home-benchmark}.log`.

## Verification

- Exact required command: `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build` — **passes, zero errors and zero warnings**.
- All four helper build scripts compile both architectures with Swift 5/macOS 14.2 and warnings as errors; C matcher
  uses `-O3 -Wall -Wextra -Werror`. Helpers are ad-hoc signed. No new shipped dependencies.
- `tests/engine/run.sh` passes, including supervisor/process trees, capability/path policy, v2 Store integrity/consent,
  mocked bridge/scaffolds and inert Mouse RPC. New manifest checks cover search/shortcut capability requirements.
- All four package `tests/run.sh` suites pass: real index/FSEvents/Spotlight/preview checks, clipboard private-pasteboard
  privacy/model tests, real /tmp screenshot watcher/Vision OCR, 50 window geometry/planning checks, 12,221 answer checks,
  currency offline/cache/deadline tests, ranking, migration and real helper RPC/host-settings/EOF tests.
- Mocked package UIs run under /tmp with loading/empty/error/retry, keyboard actions, stale-response handling and helper
  reconnect checks. Native search queue tests coalesce 1,000 queries and cover separate displays/disable/re-enable.
- `tests/features/run.sh`, `tests/keyboard/run.sh`, `tests/tabs/run.sh` pass. Their old native-window assumptions were
  changed to generic plugin-shortcut conflict coverage. Removed native Files/Launcher interaction harnesses are replaced
  by web, helper protocol and generic queue/navigation checks; live native search focus still needs the lead's review.
- `npm --prefix store test`: 35 pass. Node Store validation and built `nook-cli validate` pass for **all six** packages.
  Catalog hashes are regenerated from the final source/helpers. `git diff --check` passes.

## Lead installation and testing

Do not run a second Nook. After reviewing/merging, quit the installed instance before manually using the review build.
These commands are instructions for the lead; this branch did not install into live Application Support:

```sh
# Rebuild the separately delivered helpers if changing their native sources.
for id in file-search clips windows launcher; do bash "store/plugins/$id/build.sh"; done
for id in file-search clips windows launcher; do nook dev "$PWD/store/plugins/$id" --once; done
# Or publish the regenerated store/ content through the lead's normal Store process, then use Settings → Plugin Store.
```

Enable packages individually in Tabs & Plugins, approve trust/capabilities, and choose folders for Files/Clips. To change
chosen folders, revoke and approve again; restart/re-enable after changing OS folder/FDA grants. Each package contributes
its own native Settings pane; Windows/Launcher use normal shortcut recorders. The built CLI is at
`build/Build/Products/Release/Nook.app/Contents/MacOS/nook-cli`. For isolated CLI/dev-sync tests always set
`NOOK_SUPPORT_DIR=/tmp/<fixture>/Nook`; omit that override only for the lead's intentional live installation.

1. Files: verify Recent/filters, accents/wildcards/date/OR, live create/rename/delete, cancellation/reopen, previews,
   Open/Reveal/Quick Look, denied-folder metadata and protected-folder access. Enable Launcher separately and verify
   file results share the same helper/index; disabling File Search must remove that provider and its process.
2. Clips: inspect first-run history/pins/images, ignored/password-manager markers, Copy/Paste into a disposable editor,
   independent screenshot toggle, folder changes, OCR, pagination and explicit Trash confirmation. Denied folders must
   remain idle. Check copied image paths point into plugin data and legacy bytes stay intact.
3. Windows: grant Accessibility to the responsible signed identity, then test all layouts/Restore/display transforms,
   two pinned notches retaining different targets, closed-window refusal, migrated shortcut conflicts, desktop movement,
   pointer movement/cancellation and disable during a drag. No synthesized input was posted during automated tests.
4. Launcher: app/plugin/command ranking/history, source switches, math/units/currency/offline/time/place/color/base/percent,
   Enter/Command-Enter, Command-K actions, Ctrl-N/P, Command-1–9, Tab Quick AI, confirmation, Escape/focus and two displays.
   Toggle/revoke/uninstall and verify no helper/provider/hotkey survives. Test permission rejection and helper crash/restart.

## Risks and limits for review

- Native helpers are unsandboxed; capability gates protect host calls, not direct native APIs. Distribution signing,
  notarization/provenance and clean-profile TCC attribution remain the lead's release responsibility. Accessibility may
  be attributed to Nook, the helper or launch ancestry. Clips needs capture-folder access; reading existing recordings
  does not require starting screen recording. System commands can need Automation permission.
- AX/Space behavior, Quick Look helper windows, actual focus restoration and permission sheets were not exercised live.
  Private read-only Space/window symbols can disappear; errors refuse unsafe fallback. Graceful termination releases
  a held drag synchronously; SIGKILL/crash cannot execute cleanup.
- The generic search renderer uses SF Symbols, fixed height and asynchronous provider arrival instead of the former
  app-icon/dynamic-height renderer. Quick AI uses generic host AI completion directly; the former automatic first-saved-
  Agent handoff is not present. These are explicit presentation/integration differences for review.
- File Search's Store ID is `file-search`; old custom v1 `files` overrides and dock/group/tab-shortcut references are not
  rewritten or deleted. Their user data is preserved; replace those references explicitly when adopting the new tab.
- Nook was never launched or GUI-automated. Nothing was typed into apps, installed into /Applications or written into the user's live Nook
  Application Support, pushed, merged, published or released. Tests used generated fixtures/mocks; only the benchmark
  read accessible real-home metadata. No release/publish script ran.
