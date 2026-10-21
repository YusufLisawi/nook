# File Search

Implemented on `agent/files` for lead review. Continued and completed the interrupted work already present in this worktree.

## What ships

- Native `NSMetadataQuery` search with 25 ms debounce, incremental/live results, stale-query cancellation, scope and kind filters, and strict prefix → word-start → substring ranking. Spotlight last-used dates and a bounded history of files opened through Nook break ties.
- Metadata reads run off the UI thread. Bounded shared candidate caches and the last 32 query caches provide immediate suggestions. Each screen has its own client/request identity. Closed tabs cancel queries; 30-second heartbeats maintain visible queries and restart them after sleep. Abandoned queries expire after 120 seconds.
- Home, Developer, Downloads, and all indexed local locations; folder/app/document/image/PDF/code filters. Common code/config extensions supplement Spotlight type labels. Exclusions cover node_modules, .git, Library caches/logs/developer data, user-selected folders, and hidden/invisible files unless enabled.
- Text/code previews read at most 20 KB; image/document thumbnails use QuickLookThumbnailing and PNG data URLs. Metadata includes size, kind, modification date, and path. Preview reads/cache stay separate from search; cloud-only iCloud items receive a download hint.
- Native Quick Look panel, open, Finder reveal, copy path, copy file URL, and application discovery/open-with. No user-file deletion operation was added.
- Bundled `files` plugin, order 46, height 380: highlighted names, category icons, paths, preview pane, loading/empty/error states, retry, keyboard navigation, and actions menu. Tab follows search → scope → kind → results → preview → actions. Plain Space opens Quick Look; Shift-Space types a space. Settings control preview visibility and result count.
- Native grouped File Search Settings pane for default scope, exclusions, and hidden files. Bridge contract is documented in PLUGINS.md and capability/limits in docs/LIMITS.md.

## Files touched

New: `Nook/Services/FileSearchModels.swift`, `FileSearchService.swift`, `FileSearchPreview.swift`, `FileSearchQuickLook.swift`; `Nook/Views/FileSearchSettingsPane.swift`; `Plugins/files/{plugin.json,index.html,main.js,model.js,style.css}`; `tests/files/{NativeTests.swift,plugin.test.cjs}`; this report.

Shared: one registration line in `Nook/Core/Services.swift`; generated references to the five Swift files in `Nook.xcodeproj/project.pbxproj`; documentation additions in `PLUGINS.md` and `docs/LIMITS.md`. No changes to Extensions.swift, WebPluginHost, NotchPanel, SettingsView, project.yml, release scripts, or other plugins.

## Verification

- The exact required Release command passed with **zero compiler warnings/errors**: `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build`. Xcode emits one invocation warning, `Using the first of multiple matching destinations`, because it lists native, Rosetta, and generic Mac destinations. Log: `/tmp/nook-files-build-final.log`.
- Repeating the Release build with `-destination 'platform=macOS,arch=arm64'` passed with **zero warnings of any kind and zero errors**. Log: `/tmp/nook-files-build-native-destination.log`. The project's supported architectures were preserved; no shared build settings were changed to silence the host-destination warning.
- `nook validate Plugins/files`, JS syntax checks, and `git diff --check` passed.
- Latest 12-query Spotlight probe (Home scope): median **22 ms** to first nonempty results, **10/12 under 100 ms**, slowest **150 ms**. Repeated Nook/readme/package/swift searches returned cached rows in **<1–7 ms**; the first Nook/readme/package searches took **97/76/82 ms**. These are host measurements rather than an end-to-end WKWebView latency guarantee. Log: `/tmp/nook-files-native-final.log`.
- Mocked `window.nook` tests exercise stale initial replies (including empty live batches), stale previews, client isolation, safe text rendering, all actions/keyboard shortcuts, action-menu navigation, filters, IME, retry/error/empty states, live settings, show/close cancellation, heartbeat lifecycle, and expired-query recovery.
- Swift tests compile with `-warnings-as-errors`. They cover rank tiers/recency/frequency, accents/literal names, exclusion boundaries, dot-hidden and invisible files, code classification, recent-cache policy, bounded/binary text handling, invalid paths, real text/metadata previews, and real QuickLookThumbnailing PNG generation without presenting a window. The default test starts/stops real queries to catch unsupported Spotlight predicates, including the empty/recent query. Optional benchmark/filter runs exercise the actual search service, verify scope/kind/unique paths, and cancel each query. The filter integration test caught and fixed an Objective-C exception caused by the previous empty-query nil comparison; recent searches now use a supported date comparison.
- No Nook instance was launched, installed, or controlled. No GUI automation, clipboard mutation, file opening, user Nook data writes, push, merge, publish, or release operation was performed. The native preview test creates/removes only its own temporary fixtures and isolates preferences in a temporary UserDefaults domain.

To repeat tests from the repository root (Node and Xcode command-line tools required):

```sh
files_test_dir=$(mktemp -d /tmp/nook-files-tests.XXXXXX)
npm install --prefix "$files_test_dir" --no-save --package-lock=false linkedom@0.18.14
NODE_PATH="$files_test_dir/node_modules" node tests/files/plugin.test.cjs "$PWD"
xcrun swiftc -O -swift-version 5 -warnings-as-errors -parse-as-library \
  Nook/Core/Extensions.swift Nook/Services/FileSearchModels.swift \
  Nook/Services/FileSearchPreview.swift Nook/Services/FileSearchQuickLook.swift \
  Nook/Services/FileSearchService.swift Nook/Views/FileSearchSettingsPane.swift \
  tests/files/NativeTests.swift -o "$files_test_dir/native-tests"
"$files_test_dir/native-tests"
"$files_test_dir/native-tests" --benchmark
"$files_test_dir/native-tests" --filters
```

No application/plugin dependency was added. LinkeDOM is a test-only DOM parser installed entirely under `/tmp`; it lets the real plugin scripts run against a DOM with a mocked native bridge instead of using GUI automation. Nothing from it ships in Nook.

## Lead's manual checks

After deliberately restarting the existing Nook instance with the reviewed build (never two instances):

1. Open File Search; verify search focus, matching highlights, both panes, and rapid typing/selection without stale rows/previews. Check empty queries and no-match/error states.
2. Verify ↑↓, Enter, ⌘Enter, Space/Esc Quick Look, Shift-Space, ⌘C path copy, ⌘⇧C file paste in Finder, and ⌘K/Tab/Enter/Esc actions including Open With. Confirm native panel focus returns correctly after Quick Look and its window stays usable when the notch closes.
3. Try every scope/kind; change default scope, exclusions, and hidden files in Settings while a search is open. Check text >20 KB, images, PDFs, folders, missing/unreadable files, and cloud-only items.
4. Keep a query open while creating/renaming a disposable file in an indexed scope; verify live results. Test tab close/reopen, multiple screens, remaining open >2 minutes, and sleep/wake recovery.

## Risks and limits

- Spotlight indexing, Privacy exclusions, permissions, and mounted-volume latency govern coverage and cold latency. No filesystem crawl or Rust helper is used. Warm caches target sub-100 ms first results; a universal cold sub-100 ms guarantee is not possible. Broad gathers can continue for seconds after first results.
- Each scan considers at most 20,000 indexed candidates and returns at most 100 rows (`truncated` exposes the cap). Path exclusions are applied before further metadata reads. Very broad queries can miss useful entries beyond that cap. Cached suggestions may briefly include moved files until the live result list replaces them; actions reject unavailable paths.
- Frequent-use history covers up to 200 files opened through Nook; Spotlight provides system-wide recency. Code/config extension classification is heuristic (e.g. `.ts` can also be a transport-stream file).
- Plain Space follows the requested Quick Look shortcut even while the search field is focused; use Shift-Space for multiword names.
- Native panel display/focus, Finder/clipboard integration, and visual appearance remain manual checks because launching Nook and GUI automation were prohibited. Logic, actual Spotlight, and actual thumbnail generation were tested separately.
