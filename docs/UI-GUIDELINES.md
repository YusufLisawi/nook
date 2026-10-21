# Nook UI guidelines — the notch vibe

Nook lives in the MacBook notch. A plugin is a small, calm, dark panel that drops out of the camera housing,
does one job in a glance, and gets out of the way. Design for **a 2-second visit**, not a session.

## 1. The canvas

| | |
|---|---|
| Width | ≈ **650 pt** (the open notch is 680; 14 pt side padding) |
| Height | `height` in plugin.json, **80–400 pt** (default 210). Change live with `nook.notch.setHeight(px)` |
| Background | **Transparent.** The notch behind you is pure black. Never paint the page |
| Above you | The notch header already shows your plugin **name**, a pin and a gear. Don't repeat your title |
| Below you | The tab dock. Leave it alone |
| Scrolling | **The page never scrolls.** Lists scroll inside a container (`nk-scroll`), scrollbars hidden |
| Text | `-apple-system`, **12 px** body, 11 px secondary, 10 px uppercase labels, 13 px titles, 20–28 px hero numbers |

Rule of thumb: if it doesn't fit in 650 × 210, it's two plugins or it needs a smarter layout — not a taller notch.
Go taller (≤ 300) only for reading surfaces (teleprompter, long notes) and shrink back when done.

## 2. Tokens (injected, use them — don't hard-code)

```
--fg #fff                     primary text
--muted rgba(255,255,255,.55) secondary text, idle icons
--card rgba(255,255,255,.06)  surfaces
--card-hover rgba(255,255,255,.1)
--border rgba(255,255,255,.08) hairlines only
--accent #ff9f0a              Nook orange: the ONE highlight colour (primary action, live state)
--good #30d158  --bad #ff453a status only
--radius 14px                 cards; 8–9 px for buttons, inputs, rows; 999px for pills
```

Colour is information, not decoration. One accent per view. Greys do the rest.

## 3. Layout patterns

**Status + list + input** (most plugins: notes, proxies, history)
```
[ status pill ·········· secondary action ]   ← 1 row, optional
[ card: scrollable list (nk-scroll)        ]   ← fills the space
[ input ················· primary button   ]   ← 1 row
```

**Glanceable tiles** (monitor, home): `nk-grid-4` / `nk-grid-2` of `nk-card`s, each = label + big number + tiny visual (ring, bar, sparkline).

**Two columns** (detail views): list ~38 % on the left, detail/editor on the right. Gap 8 px.

**Focus mode** (teleprompter, timers): one huge element centred, controls in a quiet row underneath, `nook.notch.pin(true)` while active.

Spacing: 8 px between blocks, 12 px card padding, 7–9 px row padding. Keep everything on a 4 px rhythm.

## 4. Components (Nook UI kit — `nk-*` classes, already loaded)

| Need | Use |
|---|---|
| Page wrapper | `<main class="nk-root">` (flex column, full height, 8 px gap) |
| Surface | `.nk-card` (+ `.nk-tight`, `.nk-hover`) · tinted state: `.nk-tint-good/bad/accent` |
| Row layout | `.nk-row-flex`, `.nk-col`, `.nk-fill`, `.nk-grid-2`, `.nk-grid-4` |
| Text | `.nk-title` `.nk-big` `.nk-label` `.nk-muted` `.nk-small` `.nk-num` `.nk-ellipsis` |
| List | `.nk-list.nk-scroll` of `.nk-item` (hover bg; `.nk-selected`; `.nk-actions` appear on hover) |
| Buttons | `.nk-btn` · `.nk-primary` (accent) · `.nk-danger` · `.nk-ghost` · round `.nk-icon-btn` with an inline SVG |
| Status | `.nk-pill` (+ `.nk-good/.nk-bad/.nk-accent`) with a `.nk-dot` |
| Inputs | `.nk-input`, `.nk-textarea`, segmented `.nk-seg > button(.nk-on)`, `.nk-switch` |
| Progress | `.nk-progress > i[style=width:40%]` · loading `.nk-spinner` |
| Empty | `.nk-empty` → svg + `<b>` title + one muted line |
| Error | `.nk-error` (red tint + message). Inline, next to what failed |
| New rows | `.nk-in` (soft 4 px rise) |

Icons: inline SVG, 1.8–2 px stroke, round caps, `currentColor`, 15 px in buttons (SF-Symbols-like). The dock icon is an SF Symbol name in plugin.json.

## 5. States — every plugin has all four

1. **Loading** — `nk-spinner` in place of the content, never a blank panel. Show cached data first if you have it.
2. **Empty** — `nk-empty`: an icon, a friendly 2–4 word title, one line saying what to do.
3. **Error** — `nk-error` inline, plain words + what to do ("Couldn't reach Groq — check your key"). Never `alert()`.
4. **Ready** — the content.

Wrap **every** `nook.*` call in try/catch; a failed call is a state, not a crash.

## 6. Motion

- Short and soft: 120–220 ms, ease-out. Hover = background change, press = `scale(.97)`.
- Nook itself springs (response 0.42, damping 0.78); don't fight it with big entrance animations.
- Animate numbers/bars with CSS transitions, not jumps. No bouncing, no looping decoration.
- Live things may pulse gently (recording dot, live pill). Everything else holds still.

## 7. The closed notch (live activities)

`nook.activity.set({ text, symbol, color })` puts a tiny status on the **closed** notch: SF Symbol left, short text right.
- ≤ 12 characters ("12:04", "Prompting", "↓ 3 files"). It's peripheral vision, not a notification.
- Only while something is genuinely live (timer running, upload in progress, recording). `activity.clear()` the moment it's done.
- Colour = meaning: accent for "running", `--good` for "done", `--bad` for "needs you".

## 8. Interaction

- Hover-to-open means the user's pointer is already there: the primary action goes where the eye lands (top-right or the input row).
- Keyboard: mark the main input `data-nk-autofocus`. Enter submits, Esc is Nook's (closes the palette/settings/notch). ⌘A/C/V/X/Z work in inputs. See Keyboard below.
- Destructive actions: inline confirm ("Delete? Yes / No") — no modals, no `confirm()`.
- Don't steal the notch: never call `nook.notch.pin(true)` unless the user started something that needs it, and unpin after.
- Drag & drop: listen to `dragenter`/`drop` events (real file paths) — highlight the drop zone with a dashed `--border` outline.

### Keyboard

- Every action needs a keyboard path. Prefer native HTML buttons/inputs with meaningful accessible labels.
  Keep the kit's strong `:focus-visible` accent outline; reveal row actions on `:focus-within` as well as hover.
- Lists and command pills opt in with `.nk-roving`; mark their primary items `[data-nk-item="stable-id"]`.
  ↑↓ move between items (←→ with `data-nk-orientation="horizontal"`), Home/End jump, Enter activates.
  Listen for bubbling `nk:alt` for ⌘Enter. Nested controls are still reachable by Tab; inputs and sliders keep
  their own arrow keys. Skip hidden/disabled items and preserve identity when repainting lists.
- Put `data-nk-autofocus` on the main input or primary control. The host focuses it on keyboard entry;
  `nook.keyboard.focus()` requests it explicitly. Keep editors' caret and selection intact on regular updates.
- Register named actions with `nook.actions.register([...])` for the ⌘K palette; handle `nook.on('action', id)`
  and optionally `actionAlternate`. Shortcuts are local to the selected tab, never system-wide.
- Nook owns ⌘K, ⌘1…9, ⌃Tab/⌃⇧Tab, ⌘[/⌘] and Esc. Don't override them. Use a quiet `.nk-shortcuts` footer
  for the relevant hints, such as `←→ Choose  ↩ Run  ⌘↩ Edit  ⌘K Actions`. Include only actions that exist.

## 9. Customisation

- Anything a user might want different (what's shown, labels, presets, refresh rate, colours) is a **setting in plugin.json**, not a hard-coded constant. Nook draws the form.
- Apply changes live in `nook.on('settings')` — never ask the user to reload.
- Defaults should be good enough that most people never open the form.

## 10. Don'ts (these break the vibe)

- ❌ White, grey or coloured page backgrounds · ❌ page scrollbars
- ❌ Coloured edge stripes on cards (`border-left: 4px solid …`) — tint the background + use an icon instead
- ❌ More than one accent colour in a view · ❌ gradients on UI chrome · ❌ drop shadows inside the notch
- ❌ Repeating the plugin name as a heading · ❌ marketing copy, emoji confetti, "Welcome to…"
- ❌ CDN scripts / web fonts (must work offline) · ❌ `alert()` / `confirm()` / `prompt()`
- ❌ Text under 10 px or over 2 lines in list rows (ellipsis instead)
- ❌ Long-running polling faster than 1 s unless it's visibly live (and stop it on `close`)

## 11. Checklist before you ship

- [ ] `nook validate <id>` passes
- [ ] User-tweakable choices are `settings` in plugin.json and apply live
- [ ] Looks right at the plugin's height with 0 items, 3 items and 300 items
- [ ] Loading, empty, error and ready states all exist
- [ ] Only `nk-*` + tokens for colour; one accent
- [ ] No page scroll; lists scroll inside
- [ ] Every `nook.*` call has a try/catch
- [ ] Opened with `nook open <id>` and checked `nook logs <id>` is clean
