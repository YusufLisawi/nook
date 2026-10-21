# Plugin Store — agent/store

Implemented a GitHub-backed community Store and prepared the complete initial contents of `YusufLisawi/nook-plugins` in `store/`. No repository was created, pushed, or published.

## What ships

- Native Settings → **Plugin Store**, registered through `SettingsRegistry`: search by name/description/author/tag, plugin list, details, screenshots, version and installed status, source links, Install/Update, confirmed Trash uninstall, and Share.
- `nook://install/<id>` selects the detail pane and waits for an explicit Install action.
- One Foundation client shared by the app and CLI: 15-minute catalog cache, immediate cached display, offline fallback, friendly unpublished-repository state, staged installation, installed-version receipts, and app/CLI installation locks.
- Packages are pinned to Git tree hashes. Downloads prefer raw CDN files whose hashes match, falling back to immutable blobs when `main` or the CDN differs. Normal installations use one GitHub API request for the tree. Every blob and the final tree are verified before installation.
- Updates refuse unmanaged copies and local edits, recheck before swapping, preserve the previous copy in Trash, and roll back if replacement/Trash fails. Uninstall preserves Nook's saved plugin data and settings.
- CLI: `search <q> [--json]`, `install <id>`, `uninstall <id>`, `update [id]`, and `publish <path> [--yes]`. Publish validates and lists the exact files first; without `--yes` it never invokes `gh`. With confirmation it forks if necessary, builds a contribution branch from upstream `main`, replaces only `plugins/<id>`, and opens a PR without changing the local checkout.
- Standalone Store seed: README, CONTRIBUTING, MIT LICENSE, repository hygiene, dependency-free validation/index scripts, GitHub Actions PR validation and main catalog regeneration, and the **Word Count** example. Its scratchpad saves locally, handles bridge errors with retry, supports live settings and keyboard use, and provides loading/empty/error/ready states.

## Files touched

New feature files:

- `Nook/Core/PluginStoreClient.swift`
- `Nook/Services/PluginStore.swift`
- `Nook/Views/PluginStorePane.swift`
- `cli/swift/PluginStoreCommands.swift`
- `cli/swift/PluginStorePublisher.swift`
- `store/` (standalone repository contents, including `.github/workflows/catalog.yml`)
- `tests/store/` (isolated Swift client and publisher checks)
- `docs/plans/2026-10-21-plugin-store-design.md`
- `REPORT.md`

Small shared edits: one URL case in `Nook/AppDelegate.swift`; registration and main-actor annotation in `Nook/Core/Services.swift`; command dispatch/help in `cli/swift/main.swift`; Store documentation in `PLUGINS.md` and `docs/LIMITS.md`; shared client inclusion in the CLI target through `project.yml` and regenerated `Nook.xcodeproj/project.pbxproj`.

`project.yml` also sets `LM_FORCE_LINK_GENERATION` for the app: Xcode 26 completes its empty App Intents extraction instead of emitting the skipped-extraction warning. Compiler warnings remain enabled. No third-party dependencies were added. No new web bridge API was necessary.

## Verification

- The required Release command succeeds with zero source/compiler diagnostics. This Xcode installation emits one destination-selection warning when no destination is specified (both native and Rosetta Macs match). Repeating with an explicit generic macOS destination builds both architectures with **zero errors and zero warnings**:
  `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build -destination 'generic/platform=macOS' build`
- `npm --prefix store test`: **35 passing tests**, covering validation, Git-compatible tree hashing, stable index generation, and Word Count behavior with mocked `window.nook` in `/tmp`.
- `node store/scripts/validate.mjs`: example passes without warnings; `node store/scripts/generate-index.mjs` produces the included catalog.
- `bash tests/store/run.sh`: Swift compiled in Swift 5 mode with warnings as errors. Covers missing repo, cache/offline behavior, installation/receipts, CDN and immutable-blob integrity, concurrent changes on main, collisions/local edits, rollback, Trash/data retention, unsafe packages, rate limits, locking, manifest types, and publisher behavior. Networking and Trash are mocked; publisher `gh` calls are injected fakes, including confirmed paths.
- Built CLI `validate store/plugins/word-count` passes; built CLI `publish store/plugins/word-count` prints the preview without remote activity.
- `git diff --check` passes.
- The catalog's tree SHA matches the actual staged Git subtree, in addition to the Node/Swift hash tests.

Nook was never launched; no GUI automation was used. `/Applications` and live `~/Library/Application Support/Nook` data were not modified. No real install, uninstall, publish, push, merge, or release script was run.

## Lead testing and repository setup

Copy the **contents** of `store/`, including `.github`, `.gitattributes`, and `.gitignore`, into the new public `YusufLisawi/nook-plugins` repository, using `main` as its default branch. Enable Actions with permission to commit the generated catalog; branch protection must permit that bot commit or generation must be part of the merge process. `store/` intentionally has no nested `.git` directory.

After that repository is available, test in a controlled Nook session after quitting the existing copy:

1. Open Settings → Plugin Store, search `writing`, and open Word Count. Verify author/version, source, Share, and the copied install deep link. A deep link should select details without installing.
2. Install, verify the tab hot-reloads, edit the scratchpad, and use Tab/arrows/Enter/⌘Enter/Escape. Toggle character counts in plugin settings.
3. Reopen the Store offline and verify cached browsing and useful installation errors.
4. Publish a fixture revision through the lead's normal review process, refresh, and verify Update. A locally edited installed plugin must refuse an update.
5. Uninstall through the inline confirmation; verify the plugin is in Trash and saved draft/settings remain. Check equivalent CLI commands.

## Risks and limits

- Native interaction/layout, real downloads from the new repository, and an authenticated GitHub submission remain manual integration checks; the repository is not yet published and this task prohibited launching Nook or publishing.
- Plugins retain Nook's existing unsandboxed privileges. Validation checks packaging and common UI issues; source review is still required.
- Packages allow at most 200 regular non-executable files, 5 MB per file, 20 MB total, and no symlinks/hidden files/unsafe paths. GitHub API limits can still affect catalog-tree and fallback-blob requests. Screenshots display an offline fallback when unavailable.
- Publishing requires installed/authenticated `gh` and GitHub permissions. A failed confirmed submission can leave its fork or contribution branch; it never merges. Maintainers must review and merge submissions and bump plugin versions for changes.
