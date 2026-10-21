# File Search: permission-safe startup

Follow-up on `agent/files2`, after fast-forwarding `main` to `10be1b5`.

## What changed

- Startup no longer probes Desktop, Documents, Downloads, Pictures, Movies, Music or Library/cloud folders without Full Disk Access or an explicitly requested, previously successful Desktop/Documents/Downloads grant. Removable/network mount points are excluded from the kernel mount table without opening them. Exclusions precede C `stat`/`getattrlist`/directory opens; the scanner also stops at device boundaries.
- All configuration preparation, FDA detection, root validation, journal checks and scanning run on the background index queue. `start` only enqueues work. Queries and UI status remain available while that queue is blocked. Access policy is part of the catalog fingerprint, invalidating old ungated caches and rebuilding when the choice changes.
- A single quiet, tinted Files row with an SF Symbol offers “Search Desktop, Documents and Downloads instantly — Allow access” (⇧⌘A). Native Settings → File Search has the same action, Full Disk Access settings and Forget Folder Access. Only the explicit native action opens those three directories to request access. Successful reads are remembered; denied/missing folders are not retried at startup. There is no permission-request bridge API that a plugin could invoke automatically.
- Symbolic-home Spotlight metadata is merged into the same C ranking as indexed results in Files, the plugin bridge and launcher. Folder-scoped Spotlight queries are deliberately not used (see measured limitation below). Native results arrive independently of metadata gathering. Candidate predicates cover OR/subsequence/wildcard queries and are exercised against real NSMetadataQuery; unsupported TRUE/single-child compound predicates are avoided.
- Automatic previews stop before any protected URL/existence/thumbnail read. Preview path validation runs off main and rejects symlink ancestors/final symlinks. Path/name copying is metadata-only. Explicit Open/Quick Look remain available user actions.
- The Clips screenshot index was a second startup Desktop reader (`open(O_EVTONLY)` on main). It now shares the access gate before resolving paths, watching or scanning. Its cached-path filtering was kept lexical, preserving cached OCR/pins without touching protected files. Launcher sessions are cancelled when closed.

## Spotlight verification and limits

Tested a tiny, separately ad-hoc-signed Foundation executable through launchd, **without a terminal's inherited Full Disk Access**. No Nook instance was launched.

1. Explicit Desktop/Documents/Downloads/media/cloud search scopes, including **plain string scopes**, caused a real Desktop TCC request. Unified log evidence at 2026-10-21 17:32:25: `AUTHREQ_PROMPTING`, `kTCCServiceSystemPolicyDesktopFolder`, accessing identity `com.yusuf.nook.metadata-strings-probe`, message `392.3486`. That standalone job was terminated/removed; no GUI automation was used. This disproves the proposed folder-scope assumption on this Mac.
2. `NSMetadataQueryUserHomeScope` completed without a folder prompt. The independent helper's FDA sentinel returned false. Reading metadata attributes and categories also completed without prompts. However, macOS withheld all Desktop/Documents/Downloads/cloud rows from that denied identity. We cannot safely manufacture that coverage: Recent includes whatever macOS exposes; otherwise the user must choose Allow access. This limitation is also documented in PLUGINS.md and docs/LIMITS.md.
3. The committed reproducible harness, `bash tests/files/permission-probe.sh`, compiles a separate helper, runs it through a temporary launchd job with KeepAlive disabled, prints metadata/index/query timings, then removes the job. Its index/cache is under its own `/tmp` folder. It does not reset TCC or modify Nook preferences/data.

Final independent probe on this Mac (M1 Max, 64 GiB):

| Measurement | Result |
|---|---:|
| FDA sentinel readable | false |
| Safe home metadata rows, modified in last week | 33,376 |
| Protected metadata rows exposed | 0 |
| `index.start` return time | 0.029 ms |
| Accessible names indexed | 183,518 |
| Background index build, warm filesystem | 2,363 ms |
| Median query: Nook / readme / swift / report / Recent | 1.773 / 2.322 / 1.098 / 2.583 / 0.984 ms |

An earlier cold-filesystem pass indexed the same names in 5,633 ms; query medians were 0.99–2.61 ms. No `AUTHREQ_PROMPTING` entries were recorded during either gated probe. Evidence: `/tmp/nook-file-permission-probe.6j0TRn/stdout` and `/tmp/nook-files-access-probe-final.log`. Before this fix, the lead observed a Documents TCC prompt during startup, and the source unconditionally traversed protected folders. The original full-coverage/million-name benchmarks remain in `docs/reports/files2.md`; coverage differs, so these build times are not a like-for-like speed comparison.

## Validation

Passed without launching Nook:

- `bash tests/files/run.sh`: mocked web plugin; real query parsing/ranking; permission gates for home/media/cloud/mount/Data-volume aliases; symlink roots; pre-traversal exclusions; blocked configuration worker with responsive queries; safe previews; explicit-only successful grants, persisted choice and cache invalidation/revocation; real Spotlight predicate translation; FSEvents changes/restart catch-up; native tab/keyboard races.
- `bash tests/launcher/run.sh`: ranking and 56 interaction/lifecycle checks, agent handoff and failure paths.
- `bash scripts/test-clips.sh`: denied startup gate, screenshot scan/watch, OCR, pins/cache restore, deletion, folder switching/recovery and mocked plugin.
- `bash tests/files/permission-probe.sh`: real home read-only scan and safe metadata under an independent, non-FDA identity.
- Required `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build`: passes, zero compiler/linker warnings or errors. Xcode itself emits its existing `Using the first of multiple matching destinations` invocation warning.
- Universal `xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build -destination 'generic/platform=macOS' build`: passes for arm64/x86_64, **zero warnings of any kind and zero errors**.
- `git diff --check` passes.

## Lead's live check

Use an isolated macOS account or an independently installed test identity with no existing FDA/folder grants; do not run two Nook instances. On first launch, open the notch immediately and switch to Files: no permission dialog should appear. Recent shows indexed accessible files and any metadata macOS allows; the one Allow access row is visible.

Choose Allow access (or ⇧⌘A); only then should macOS request Desktop/Documents/Downloads. Deny one folder to check the calm, partial-access state; grant another and create a file there to check Recent/live indexing. Restart to check the remembered successful grants. Settings → File Search exposes the same controls and Full Disk Access link. A blocked row's automatic preview must not prompt; explicit Open/Quick Look can request access. Check Clips starts without requesting Desktop access, then indexes screenshots after access is allowed.

## Remaining limits

There is no public silent per-folder TCC preflight. Remembered grants mean a prior explicit Allow action actually opened that directory successfully. If TCC is reset externally after that, forget Nook's remembered folder choice before restarting; a new read could otherwise request permission again. Denials are never saved as grants. Full Disk Access refreshes when Nook becomes active. Forget Folder Access changes Nook's indexing choice, not macOS's permission database.

Without FDA, Library (including cloud containers), media folders and removable/network roots remain conservatively excluded from direct reads. Folder-root symlinks are rejected; descendant symlinks remain searchable references. Spotlight coverage is bounded to 20,000 candidates and governed by macOS access/Spotlight Privacy. No third-party dependencies were added. No GUI automation, live Nook data writes, /Applications changes, pushes or releases were performed.

## Files touched

New: `FileSearchAccessPolicy.swift`, `FileSearchAccess.swift`, `tests/files/FileAccessTests.swift`, `PermissionProbe.swift`, `permission-probe.sh`, this report.

Updated: filename index C/Swift, query path normalization, metadata models/fallback, FileSearchService, native Files tab/Settings, launcher file source plus one close-cancellation line, Clips startup/index plus regression test, test scripts/stub, PLUGINS.md, docs/LIMITS.md and generated Xcode project entries. No shared registration switch was expanded.
