---
name: nook
description: Build, change and debug plugins for Nook, the open-source macOS notch app (github.com/YusufLisawi/nook). Use whenever the user says "nook", "notch app", "nook plugin", "add a tab to the notch", "make a notch widget", or wants a new feature/tool/panel in the notch (dashboards, API widgets, controls for other apps, timers…), or asks about Nook's UI style, plugin API, CLI, limits, or its native Swift code (dictation, proxy, mixer, hotkeys, notch window).
---

# Nook

Nook is a macOS notch app (SwiftUI + AppKit). Every tab in the notch is a **plugin**: a folder with `plugin.json` +
`index.html` (+ JS/CSS), rendered in a transparent WKWebView with a native bridge, `window.nook`.
**Plugins load at runtime — never rebuild the app to add or change one.** Source: https://github.com/YusufLisawi/nook

## Golden rules

1. **Feature request → plugin first.** Only touch Swift when `nook limits` says it's impossible as a plugin.
2. **Read before you build:** `nook api` (bridge + plugin format), `nook guide` (UI rules), `nook limits` (what needs Swift). They are the source of truth and match the installed version.
3. **Look like Nook:** use the injected `nk-*` UI kit + tokens; transparent page; no page scroll; one accent (`--accent`); no coloured edge stripes; loading / empty / error / ready states.
4. **Make it customisable:** anything a user may want different goes in `plugin.json` → `"settings"`; Nook renders the form. Apply live on `nook.on('settings')`.
5. **Never type into the user's apps** with GUI automation to test. Test with `nook open`, `nook logs`, `nook storage`, `nook prefs`, screenshots and files.

## Build a plugin (the loop)

```bash
nook new <id> --name "Name" --symbol <sf.symbol> [--height 210] [--order 100]
#   → ~/Library/Application Support/Nook/Plugins/<id>/   (live in the notch immediately)
# edit index.html / main.js / style.css — Nook hot-reloads on save
nook open <id>           # show it (notch under the mouse)
nook logs <id>           # console + uncaught errors   (-f to follow)
nook storage <id>        # saved data        ·   nook prefs <id>   # settings values
nook validate <id>       # must pass before you say "done"
```

- Ids: lowercase-dashes; folder name = id. A user plugin with a bundled plugin's id overrides it (`nook eject <id>` copies one to customise).
- Canvas ≈ **650 × height** pt (80–400, user can change per tab). Design for 650 × 210 and stretch.
- Every `nook.*` call is async and can fail: `try { … } catch (e) { show .nk-error }`.
- `nook.shell()` + `osascript` reach almost anything on the Mac (control apps, run CLIs, read files). `nook.fetch()` has no CORS.

## Bridge cheat sheet (full: `nook api`)

`nook.settings.get/set/open` + `nook.on('settings')` · `nook.storage.get/set/all` · `nook.shell(cmd,{timeout})` ·
`nook.fetch(url,{method,headers,body})` · `nook.system()` · `nook.ai.chat(messages,{json})` (LLM via the user's Groq key) · `nook.clipboard.read/write` · `nook.open(url|path)` · `nook.notify(title, body)` ·
`nook.activity.set({text,symbol,color}) / clear()` (closed-notch status) · `nook.notch.close/pin(bool)/setHeight(px)` ·
`nook.on('open'|'close'|'show'|'drop'|'dragenter'|'dragleave'|'audio'|'proxy'|'dictation', cb)` ·
`nook.audio.*` (devices, per-app volume) · `nook.commands.*` (AI Commands) · `nook.proxy.*` · `nook.dictation.*` · `nook.timer.*` · `nook.plugin` ({id,name})

## Starter layout (uses the kit)

```html
<main class="nk-root">
  <section class="nk-card nk-fill nk-col">
    <div id="list" class="nk-list nk-scroll nk-fill"></div>        <!-- rows: .nk-item -->
    <div id="empty" class="nk-empty" hidden><svg …/><b>Nothing yet</b><span>One line on what to do.</span></div>
  </section>
  <form class="nk-row-flex"><input class="nk-input nk-fill" placeholder="Add…"><button class="nk-btn nk-primary">Add</button></form>
</main>
```

## Changing Nook itself (Swift)

Clone https://github.com/YusufLisawi/nook (the user may already have it, e.g. `~/Developer/nook`). Map:
`Nook/NotchController.swift` (panel, hover, swipes) · `Nook/NotchViewModel.swift` (state, sizes, activities) ·
`Nook/Core/WebPluginHost.swift` (bridge — add `nook.*` calls in `handle` and `bridgeJS`) · `Nook/Core/PluginRegistry.swift` ·
`Nook/Services/*` (media, timers, shelf, stats, proxy, mixer, dictation) · `Nook/Views/*` · `NookUI/nook-ui.css` · `cli/swift` (this CLI).
Build: `xcodegen generate && xcodebuild -scheme Nook -configuration Release -derivedDataPath build build`. Document new bridge calls in `PLUGINS.md`.
