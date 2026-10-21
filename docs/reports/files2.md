# File Search rebuild — agent/files2

Replaced the default web File Search tab with native SwiftUI and a shared, persisted filename index. No Nook instance was launched, installed, or controlled. No user files were opened, copied, or trashed during testing. No writes were made to the user's Nook Application Support data, and no push/merge/publish/release operation ran.

## Built

- A packed C index with separate contiguous name/path storage, Unicode case/diacritic normalization, a character-presence mask, the oil-find NEON byte finder, a bounded top-results heap, and complete-candidate incremental narrowing. Searches inspect the full catalog; displayed rows are capped at 100. C compiles at `-O3` independently of the app's size optimization.
- Background home traversal at launch. Defaults skip Library, hidden files, cache/dependency/build folders, common package/app internals and descendant symlink traversal. Native grouped Settings configures exclusions, additional roots and inclusion switches. Protected locations are skipped with a notice. Explicit root aliases use physical paths, including macOS `/tmp` → `/private/tmp` aliases.
- A checksummed, versioned binary cache with private permissions under `~/Library/Caches/com.yusuf.nook/FileIndex`. Scope and filesystem-journal identity invalidate incompatible caches. FSEvents updates individual files/subtrees, replays from the saved watermark after restart, and rebuilds after lost history/root changes. Checkpoints run at most once per five seconds, outside the search lock; normal quit flushes. Deleted-entry compaction happens in the background.
- Exact basename → prefix → word start (ASCII camel case included) → substring → subsequence ranking. Added-to-directory date falls back to filesystem creation. Added/modified recency and Nook-opened frecency sort within each name tier. Empty Recent shows newest added/modified files, including never-opened downloads; folders are available with the Folder filter.
- AND words, OR `|`, `!` exclusions, quoted phrases, wildcards, absolute/tilde folder scopes, `ext:`, `kind:`, `file:`/`folder:`, binary-unit `size:`, `dm:` and `added:` date filters. Invalid syntax produces inline errors. See PLUGINS.md for exact semantics and bounds.
- Native borderless search, soft row selection, matched-character highlights, hidden scrollbars, kind picker/Tab cycling, metadata/text/Quick Look thumbnail preview, file drag-out, local Actions ⌘K and the requested open/reveal/Quick Look/copy path/copy name/confirmed Trash shortcuts. Query replacement and preview replies cannot act on or overwrite newer results.
- Launcher Files source using this same index, after other sources and before the final Ask AI row; `file:` and `f ` prefixes restrict it. Launcher Settings has a Files source switch. Existing saved source selections may require enabling this new source there.
- Existing `nook.files.*` bridge preserved, now backed by the own index. Added `copyName`, confirmed `trash`, `status`, and `rebuild`; retained open-with and file-URL copy. The former Spotlight engine runs only as a bounded first-build/rebuild fallback and applies the same query filters. A user web `files` override still works.

Studied `/tmp/oil-find` at `e63c7150ccbd401a1375c08215d1386b56dd9471`: packed IndexStore/persistence/mutation, Searcher/SearchCache, Scanner/IndexConfig, FSWatcher and IndexUpdater. The C byte finder is adapted from that MIT code; its copyright is in the C header and the complete license is in THIRD_PARTY_NOTICES.md, also bundled as an app resource. No package manager or shipped third-party dependency was added.

## Measurements on this Mac

Apple M1 Max, 64 GiB RAM, arm64 optimized CLI harnesses. Home traversal was read-only; generated test fixtures and benchmark caches live under `/tmp`. Filesystem caches were warm. These are engine timings, not rendered-frame measurements.

| Metric | Before: Spotlight service | After: own index |
|---|---:|---:|
| Own catalog / traversal | Delegated to Spotlight; no own catalog | 236,777 names / 8.538 s |
| Restart catalog load | New metadata queries | 0.125 s |
| Checkpoint write / cache size | No own catalog | 0.099 s / 45,632,365 bytes |
| Own index allocation after traversal | N/A | 60.0 MiB |
| Standalone helper peak RSS | 35.0 MiB, excludes Spotlight daemon | 93.0 MiB after traversal |
| First nonempty result, 12-query median | 19.5 ms (first four cold queries: 92.5 ms median) | Query medians below |
| Completion or 4-second measurement cap, median | 1,295.5 ms; two readme gathers hit the cap | Full-catalog result calculation per query below |

Memory is an explicit tradeoff: the old helper delegates indexing/memory to Spotlight. Helper RSS numbers include different framework overhead and are not the complete app's memory usage.

| Query | Before first request, first rows | Home median / p95 (25 runs) | 1M names median / p95 (25 runs) |
|---|---:|---:|---:|
| Recent | — | 1.256 / 1.294 ms | 4.233 / 4.330 ms |
| Nook | 99 ms | 2.019 / 2.044 ms | 2.851 / 2.942 ms |
| readme | 86 ms | 2.656 / 2.728 ms | 3.700 / 3.803 ms |
| package | 107 ms | 1.496 / 1.513 ms | 3.774 / 3.832 ms |
| swift | 11 ms | 1.317 / 1.385 ms | 3.679 / 4.191 ms |
| FileSearch | 19 ms | 1.307 / 1.350 ms | 3.921 / 3.941 ms |
| PLUGINS | 20 ms | 1.540 / 1.574 ms | 3.774 / 3.862 ms |
| report | 119 ms | 2.951 / 2.987 ms | 3.745 / 3.822 ms |
| invoice | 154 ms | 1.901 / 1.943 ms | 3.762 / 3.782 ms |
| rpt (subsequence) | — | 3.688 / 3.725 ms | 5.053 / 5.120 ms |
| *.png | — | 2.245 / 2.278 ms | 5.351 / 5.569 ms |
| ext:pdf;docx added:week | — | 1.715 / 1.732 ms | 5.758 / 5.867 ms |

One million synthetic names with long directory paths: build 1.019 s, allocation 176.0 MiB. Name queries above deliberately have 125,000 matches each. An incremental `r → re → rea → read → readm → readme` pass, including Swift query setup/result extraction, measured 15.054 → 8.000 → 6.665 → 6.253 → 6.177 → 6.129 ms. Home incremental `readme` finished in 0.241 ms. Old repeated cached suggestions could return in 1–7 ms while their underlying Spotlight gathers continued; the new numbers measure full-catalog calculations rather than cached top rows.

Logs: `/tmp/nook-files2-before-memory.log`, `/tmp/nook-files-before/benchmark.log`, `/tmp/nook-files2-benchmark-final.log`. To repeat: `bash tests/files/index.sh --benchmark`; for only the million-name pass, add `--synthetic`. The harness prints traversal time, allocation/RSS, cache save/load, per-query medians/p95s and incremental timings.

## Verification

- Required exact `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build`: **BUILD SUCCEEDED**, zero compiler/linker errors or warnings. Xcode itself emits its existing `Using the first of multiple matching destinations` warning for native/Rosetta/generic Mac destinations. This is the sole warning from that exact invocation; it is not suppressed or hidden.
- Same Release build with `-destination 'generic/platform=macOS'`: **BUILD SUCCEEDED, zero warnings of any kind and zero errors**, including arm64 and x86_64. Logs: `/tmp/nook-files2-build-final.log`, `/tmp/nook-files2-build-zero-warnings.log`. Universal architecture support is preserved.
- `bash tests/files/run.sh`: old mocked `window.nook` plugin suite, real bounded text/thumbnail previews, real own-index bridge cancellation/promise-settlement checks, parser/ranking/recency/narrowing tests, cache watermark/checksum/corruption tests, scanner policy/symlink/package tests, real FSEvents creation/modify/subtree rename/delete/restart catch-up, and isolated native keyboard/action/stale-reply tests. Swift and C harnesses compile with warnings as errors. All pass without launching the app.
- `bash tests/launcher/run.sh`: ranking benchmark, 48 native interaction checks (including file prefixes/source switch/stale file replies) and mocked agent handoff pass.
- `bash tests/tabs/run.sh`: 50 model and 39 integration checks pass. `bash tests/keyboard/run.sh` and `bash Tests/focus/run.sh` pass.
- `NOOK_RESOURCES="$PWD" nook validate "$PWD/Plugins/files"` and `git diff --check` pass. The bundled web plugin is unchanged and remains usable as an override/bridge reference.

## Lead's manual checks

Quit the currently running Nook before deliberately testing the reviewed build; run only one instance.

1. Open Files and verify search focus, launcher-like spacing/highlights, empty Recent, error/loading states, rapidly typed queries, and previews at the notch's actual size. Try `rpt`, `report !draft`, `report | invoice`, `*.png`, `~/Desktop/ screenshot`, `ext:pdf;docx`, `kind:image|folder`, `folder:`, `size:>10mb`, `dm:today`, `added:week`.
2. Verify arrows, Return, ⌘Return, Space/Esc Quick Look, Shift-Space typing, ⌘C, ⌥⌘C, Tab/Shift-Tab filters, and local ⌘K/arrow/Return/Escape actions. Confirm ⌘⌫ asks first; Escape/selection changes cancel it. Use only a disposable file to test confirmed Trash. Drag a disposable result into Finder/another app.
3. Download/copy a file with an old modification date into Downloads; confirm its added date brings it into Recent. Modify/rename/delete disposable files while searching. Quit, create another disposable file, restart, and verify catch-up without a full scan. Open a file repeatedly through Nook and verify query-tier frecency.
4. Change roots/exclusions/inclusion switches in Settings; verify rebuilding, status, hidden/package filtering and permission notices. Grant Files & Folders access and rebuild if required. Check cloud placeholders and large/binary/missing files.
5. Enable Files in Launcher Settings if needed. Test plain queries and `file:` / `f ` prefixes, open/reveal and stale typing. Check multiple displays and tab close/reopen. For existing user `files` web overrides, temporarily disable the override to review the native tab, then verify its bridge still works.

## Files touched and merge notes

New production files: `Nook/Services/Files/{FileNameIndex.c,FileNameIndex.h,NookFiles-Bridging.h,FileIndexQuery.swift,FileNameIndex.swift,FileSearchTab.swift,FileSpotlightFallback.swift,FileSearchWebShortcuts.swift,LauncherFileSource.swift}`; THIRD_PARTY_NOTICES.md.

Feature-specific replacements: FileSearchService.swift, FileSearchModels.swift, FileSearchSettingsPane.swift. Existing preview and Quick Look files and `Plugins/files/` are unchanged.

Small shared edits: PluginRegistry.swift (native Files and skip bundled web copy; user overrides retained), NotchRootView.swift (one case), NotchKeyboard.swift (local native key route), Services.swift (quit flush), LauncherRanking.swift (source/prefix), LauncherFeature.swift (async results and open/reveal). project.yml explicitly adds the optimized C source, bridging header and license resource; generated project.pbxproj reflects them. Regenerate the project after merging parallel branches.

Tests: new IndexTests/WatcherTests/TabStateTests/TabStateStubs plus index/watcher/tab scripts under `tests/files`; existing native file tests/run script adjusted. Launcher/tabs test stubs and launcher interaction coverage updated for the new integration. Documentation: PLUGINS.md, docs/LIMITS.md, this REPORT.md.

## Risks and limits

- Native presentation, Quick Look focus, real clipboard/Finder/open/Trash effects and drag destinations remain manual checks because app launch and GUI automation were prohibited. Engine/state tests do not establish end-to-end frame latency.
- More roots, longer names, complex OR expressions, busy CPUs/disks or network volumes can exceed one frame. Initial scans and lost-history rebuilds take background time; large subtree merges share the search lock briefly. Quitting during an active scan may wait for that read-only scan before flushing.
- Package/kind recognition is heuristic. Unknown package extensions can be excluded in Settings; `.ts` prefers source code. Descendant symlinks are never traversed; explicit root aliases resolve physically. Date Added availability varies by filesystem/provider, with creation fallback.
- Spotlight fallback coverage is partial and bounded until the own catalog is ready; its candidates are filtered correctly, but some OR/subsequence matches wait for the catalog. Spotlight Privacy does not restrict the own filesystem index; use File Search exclusions.
- Paths are limited to 4,095 bytes and 256 traversal levels; name/path tables each use 32-bit offsets. Catalogs approaching multi-gigabyte string tables are outside the tested range. No content indexing, pinyin/transliteration, regex or complete oil-find grammar is included.
