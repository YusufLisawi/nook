# Launcher smart answers

Built on `agent/answers`; incorporated `main` through `7f543bc` (including the lead's File Search tab changes).
No dependencies, JavaScript bridge APIs, Settings panes, or web plugins were added.

## What changed

- A native `LauncherAnswerProvider` protocol, value-only answer/action model, and `LauncherAnswers.register(_:)` registry.
  Each provider is one new file under `Nook/Services/Launcher/Answers/`. Objective-C module discovery means adding a
  provider requires no launcher-view, startup-list, or other-provider edit. Discovery is tested with an otherwise
  unreferenced provider in a separate file under optimized Swift compilation.
- Each keystroke evaluates providers off the main thread. Every provider has a serial queue and a 2 ms response deadline;
  late results are discarded, busy providers cannot accumulate jobs, and cancelled/stale queries cannot update the UI.
  Optional asynchronous refinement re-evaluates cached answers without blocking input.
- Seven providers: safe recursive-descent math (functions/constants/percentages/operator words), units across eleven
  dimensions, currency, time/date/time-zone arithmetic, opaque HEX/RGB/HSL colors with a swatch, integer bases, and
  percentage change. All requested example queries are covered by table-driven tests. No AI, eval or NSExpression.
- A generic Raycast-style card above regular results: section label, two centered values, dimmed operators/connectors,
  pill badges, split divider/arrow and optional update note. Default selection is the card. Arrows reach normal results;
  Return copies/closes; Command Return pastes; Command K exposes copy actions and provider actions. Five normal rows remain
  visible and all results remain scrollable. Height math adds 156 pt without typing animations.
- Currency uses the fixed no-key USD feed from ExchangeRate-API, defaults to the locale currency (MAD for Morocco),
  persists rates/timestamps only in the Launcher cache, and throttles all attempts to once hourly, including failed first
  use across restarts. Cached data remains usable offline. Missing rates show an honest loading/unavailable state.
  The source attribution link is available through currency actions.

## Files touched

New:

- `Nook/Services/Launcher/Answers/LauncherAnswer.swift`, `LauncherAnswers.swift`, `LauncherAnswerCard.swift`,
  `LauncherAnswerInteraction.swift`.
- `Nook/Services/Launcher/Answers/{Math,Units,Currency,Time,Color,Base,Percentage}AnswerProvider.swift`.
- `tests/answers/`: provider tables/fuzz/performance, drop-in discovery, registry deadlines/cancellation, mocked currency
  persistence/throttling/offline tests, inert launcher interaction tests, and an offscreen SwiftUI card renderer.
- This `REPORT.md`.

Small integration edits:

- `LauncherFeature.swift`: startup discovery, asynchronous answer state/cancellation, selection/keyboard routing and height.
- `LauncherView.swift`: mount the generic card/actions and answer footer; regular result rendering stays shared.
- `tests/launcher/run.sh`: compile answer dependencies with inert output and allow the answer interaction test entry point.
- `PLUGINS.md`: syntax, currency behavior, and **How to add an answer provider**.
- `docs/LIMITS.md`: supported behavior and limits.
- `Nook.xcodeproj/project.pbxproj`: regenerated; regenerate again when combining other agents' files.

## Verification

- `bash tests/answers/run.sh`: 12,221 provider checks, including 12,000 deterministic fuzz inputs; registry deadline,
  cancellation/background execution/refinement; URLProtocol currency-cache persistence/hourly-throttle/offline tests;
  24 native answer interaction checks with inert output; existing launcher ranking and mocked agent handoff. Tests use
  in-memory preferences or `/tmp`, never live Nook application-support data. No real currency network calls in tests.
- Warmed provider p95 measurements: math 0.135 ms, units 0.156 ms, currency 0.189 ms, time 0.207 ms, color 0.027 ms,
  bases 0.025 ms, percentage change 0.141 ms. All are below 2 ms; the registry independently discards over-budget results.
- `bash tests/launcher/run.sh`: existing 56 native launcher checks, ranking benchmark, and mocked agent handoff passed.
- `bash Tests/focus/run.sh`: passed; no focus rings.
- `bash tests/files/tab.sh`: the lead's updated native File Search tab tests passed.
- Required `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build`:
  build succeeds, zero compiler/linker errors or warnings. Xcode itself emits the pre-existing **Using the first of multiple
  matching destinations** warning, also recorded in `docs/reports/launcher.md`. Exact log: `/tmp/nook-answers-build-final-exact.log`.
- The same Release build with `-destination 'generic/platform=macOS'`: zero warnings of any kind and zero errors;
  `/tmp/nook-answers-build-final-generic.log`. No warning suppression or architecture restriction is added.
- SwiftUI cards were rendered and visually inspected offscreen, without launching Nook or creating a window.
  Preview: `/tmp/nook-answer-cards.png`. Reproduce with:

  ```sh
  swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macos14.2" \
    Nook/Services/Launcher/Answers/LauncherAnswer.swift Nook/Services/Launcher/Answers/*Provider.swift \
    Nook/Services/Launcher/Answers/LauncherAnswerCard.swift tests/answers/RenderCards.swift -o /tmp/nook-answer-render
  /tmp/nook-answer-render
  ```

- `git diff --check`: passed. No plugin was added/changed, so no new plugin validation target is needed.

## Lead's manual test

Use only one Nook instance: quit the existing copy before running this branch's build yourself.

1. Toggle the launcher and try the screenshot queries: `200 + 12`, `1000$`, `time in spain`,
   `2 hours from now in spain`. Check the two halves, pills, update note, calm selection, and instant resizing while
   adding/deleting characters. Try long results and a small display. Normal results/Ask AI must stay below the card.
2. Check arrows between the card and regular results, Return to copy/close, Command Return from a disposable editor,
   and Command K → Copy result / Copy expression / Copy with units. Escape dismisses actions, clears the query, then
   closes. Existing Command 1–9 still targets regular results; Tab still opens Quick AI. Check VoiceOver labels.
3. Try `10 km in miles`, `5'11" in cm`, `100f to c`, `3 cups to ml`, `1.5 GB in MB`,
   `5pm london in new york`, `days until christmas`, `unix 1792600000`, `#f90 to rgb`,
   `255 in hex`, `0xff in binary`, and `from 80 to 100`. Ordinary `arc`, `notes`, `rewrite` must not show a card.
4. With a connection, `100 eur to mad` should load rates then show the update age. After a successful cache, try offline
   and after restarting: the answer should remain available with its source timestamp. With no cache and no connection,
   there must be no invented conversion and no result to copy. Currency actions include the source link.
5. Verify Command Return refuses a missing/changed target and reports missing Accessibility without typing. Paste leaves
   the result on the clipboard. Review multi-display behavior and Quick AI → Escape restoring the smart-answer card.

## Risks and limits

- Nook was never launched; no GUI automation, input events, external app activation or clipboard writes were performed
  by tests. `/Applications` and live `~/Library/Application Support/Nook` were not modified. No release/publish scripts,
  push, publication, or merge into main was performed. Only the lead-requested incorporation of main into this branch.
- AppKit focus, actual paste, screen-reader behavior, multi-display layout and real notch animations still need the manual
  checks above. The offscreen renderer verifies card layout, not panel lifecycle.
- The 2 ms rule bounds result acceptance/waiting; Swift cannot forcibly terminate arbitrary provider code. A slow provider
  finishes on its own queue and is skipped by later searches. OS scheduling is not a real-time guarantee.
- Math uses Double, bounded recursion/tokens and 13 significant digits. Trig is radians; `%` means percentage, not modulo.
  Both decimal marks work; a lone comma is decimal. Invalid/incomplete expressions decline without hiding search results.
- Cups and other culinary measures are US; only explicit imperial gallons use Imperial volume. SI byte prefixes are
  decimal and IEC prefixes binary. Unit-only quantities choose the locale's system or a useful counterpart.
- Country names choose mainland/capital zones; explicit cities/IANA IDs handle alternatives. Zone conversion uses today
  in the source zone; DST gaps decline and repeated times use the first occurrence. Date/relative day arithmetic is Gregorian.
- Currency feed data updates daily, may be stale/offline, and is indicative. First use requires network access. Currency
  display rounds to two decimal places; numeric copy keeps up to 13 significant digits. Symbols `$`, `¥`, `dh` resolve to
  USD, JPY and MAD. Opaque colors only; integer bases are bounded to a signed magnitude of UInt64.max.
