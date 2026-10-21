# Cleaner permission fix

Cleaner now measures and cleans accessible candidates while counting protected skips, instead of failing an entire category. Ordinary cleanup uses the native system Trash API. Empty Trash goes directly through Finder without first reading `~/.Trash`.

## Root cause and reproduction

Ran the original generated zsh through a mocked `nook.shell` against the real HOME, **scan only**:

- Caches exited 1 after `du` reported `Operation not permitted` for protected cache directories. The batch's `|| return 1` discarded every accessible sibling's result.
- Trash exited 1 with `Cannot read folder: …/.Trash`. Both emptying and ordinary cleanup required readable/listable Trash before doing any work. That gate fails under normal macOS TCC restrictions.
- Ordinary cleanup used `mv` into a manually constructed Trash path, exposing it to the same permission gate and bypassing native Trash behavior.

The fixed read-only scan returned success for caches and logs with empty stderr. On this machine it measured 88 accessible cache candidates and counted 3 protected skips. Trash returned `UNKNOWN`, without requesting filesystem or Finder access.

## Implementation and files

- `Plugins/cleaner/shell.js`: fixed-root scans check enumeration access, skip unreadable candidates, retry failed `du` batches individually, preserve accessible totals, and return skip counts. Trash size stays unknown; confirmed emptying invokes Finder directly. Removed shell-based moves and Trash preparation.
- `Nook/Services/CleanerEngine.swift` (new): validates fixed home roots, rejects symlink components/candidates, rechecks item identity and download age, measures without following symlinks, and calls `FileManager.trashItem`. Per-item permission failures are counted; other move failures remain reportable. Measurement has a 120-second timeout per candidate.
- `Nook/Services/CleanerBridge.swift` (new): registers `nook.cleaner.clean(category, days)` and serializes work off the main thread across notches.
- `Nook/Core/Services.swift`: one registration line. `Nook.xcodeproj/project.pbxproj`: generated references for the two new Swift files.
- `Plugins/cleaner/main.js`, `index.html`: partial results, skip summaries, one Full Disk Access hint/button, selectable unknown-size Trash, Finder Automation guidance, keyboard navigation/confirmation, and scan cache version 2.
- `PLUGINS.md`, `docs/LIMITS.md`: bridge contract and permission/safety limits.
- `tests/cleaner/`: shell, native, and mocked-plugin regression tests; optional read-only real-home scanner.

The existing Apple Events entitlement and `NSAppleEventsUsageDescription` are present. No new permissions, dependencies, or Settings panes were added.

## Verification

- `./tests/cleaner/run.sh` — PASS. Swift 5/macOS 14.2 compilation uses `-warnings-as-errors`. Shell/UI logic runs with a mocked `window.nook`; all destructive test operations use generated HOME/Trash fixtures under `/tmp`. The native tests inject only the final Trash operation, so the user's actual Trash is never touched.
- Covers `chmod 000` files/directories, unreadable descendants, readable siblings after failed `du`, inaccessible roots, denied moves, symlink roots/items, package isolation, download age/folder exclusions, an unlistable fake Trash destination, unknown-size Trash selection, Finder denial, stop-after-empty-failure, keyboard actions, and old cached permission errors.
- `nook validate Plugins/cleaner` — PASS. `git diff --check` — PASS.
- Required unqualified Release build command succeeded with zero compiler warnings/errors. Xcode itself printed one “multiple matching destinations” warning (this Mac exposes arm64 and x86_64 destinations).
- Release build with an explicit destination succeeded with **zero warnings and zero errors**:

```sh
xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build -destination 'platform=macOS,arch=arm64' build
```

## How to test

Run `./tests/cleaner/run.sh` and `nook validate Plugins/cleaner`. Optionally run `node tests/cleaner/scan-home.cjs`: it exposes/calls only generated scan scripts against HOME and never performs cleanup.

For manual review with a single Nook instance, scan as a normal user without Full Disk Access. Accessible sizes should appear beside protected skip counts and one privacy hint. Confirm ordinary cleanup and verify moved items are recoverable in Finder Trash. Trash should say “Size unknown” and remain selectable; confirming it may request Automation permission for Finder. Denying that permission should give actionable guidance and prevent subsequent moves. The new native bridge requires the rebuilt app.

## Risks and limits

- Live Nook, actual system Trash operations, Finder emptying, and macOS permission prompts were deliberately not exercised. No Nook launch, GUI automation, `/Applications` changes, or Nook Application Support writes occurred.
- An immediate candidate with unreadable descendants stays entirely intact and counts as one skip. This conservatively underestimates accessible space inside partially protected directories.
- TCC/SIP/ownership/locked files can still block particular candidates. Full Disk Access may help; it cannot override all protections. Sizes are allocated-byte estimates and can change while apps run. Moving to Trash frees space only when Trash is emptied.
- Empty Trash permanently affects all Finder Trash, including mounted volumes, and runs before new items are moved. It remains explicitly opt-in each run.
- Homebrew retains its separately confirmed, permanent `brew cleanup -s` behavior and can report its own failures. Its scan estimate covers the standard home cache root; custom `HOMEBREW_CACHE` paths are not measured.
