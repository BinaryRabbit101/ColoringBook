# Backlog — Issues & Feature Requests

First logged 2026-08-06 from playtest feedback. Status: `open` → `in-progress` → `done`.
Completed entries move, with their full done-notes intact, to
[BACKLOG_ARCHIVE.md](BACKLOG_ARCHIVE.md) — the done-notes are the project's
institutional memory (decisions, gotchas, smoke counts); nothing is deleted.

## Open

### BL-8: DLC support + backend server — `server + client integrated` (2026-08-06; Phases 0–5 of docs/DLC_SERVER.md §12)
Longer-term: introduce DLC coloring-book packs. Backed by a (most likely
Laravel) server handling:
- user accounts and cloud-synced game saves
- DLC entitlement/delivery
- uploading and managing coloring books and pages (admin tooling that feeds
  the region-mapping pipeline)
The Laravel app lives at `server/` (see `server/CLAUDE.md` and
`docs/SERVER_BUILD_PLAN.md`): accounts/auth/parent dashboard, progress sync,
catalog + free-pack DLC delivery, paint-layer sync, admin upload/validation/
preview/publish. 416 tests green. Still open: Phase 0 client work (`book_uid`,
save v2, `user://dlc` discovery, runtime textures), payments (Phase 6), and
deploy to the mini-pc.
- 2026-08-07: **payments (Phase 6) deliberately deferred** — the user will pick
  the provider/pricing/COPPA-consent shape when ready; everything else in this
  entry has shipped in the meantime (deploy, sync, DLC, authoring, erasure).
- Affected: `server/` (Laravel app in this repo), `docs/DLC_SERVER.md`,
  `docs/SERVER_BUILD_PLAN.md`

## Recently completed

### BL-48: The overlay layer, sized for a phone — `done` (2026-08-08)
Playtest on an iPhone in portrait (web build): "the buttons and login forms, etc.
on mobile are difficult to see and work with". The gameplay layer had its mobile
pass (M6 / BL-21 / BL-33); the overlay layer never did. `canvas_items` + `expand`
means the logical canvas never narrows below 1152, so on a ~390 pt screen every
overlay was drawn at **a third** of its authored size: the settings panel floated
at 52 % of the width with 22 px type, and the account email clipped to
"Binaryrabbit101@gmail.c…" beside a 150 px Manage button.
- **One mechanism, three numbers** — `OverlayMetrics`
  (`scripts/components/overlay_metrics.gd`, a `Node` that parents itself to the
  overlay and dies with it). `squeeze` = logical canvas px per POINT, *measured*
  (`viewport.x / (window.x / screen_get_scale())`) and clamped to ≥ 1;
  `content_scale` = `min(squeeze, 2.4)`; `min_touch_px` = `44 pt × squeeze`,
  floored at DESIGN.md's 48. **Desktop is unchanged by construction**: a desktop
  window is bigger than the 1152 px base, so its squeeze clamps to exactly 1.0 and
  every authored number comes back byte-identical — there is no "desktop" branch
  anywhere.
- **Content stops growing; fingers do not.** The cap exists because the panel's
  inside is ~940 px and the widest unwrappable string in the layer ("Sync pictures
  too (uses more data)", on a `CheckBox`, which cannot wrap) is ~790 px of it at
  2.4×. The touch floor deliberately uses the **uncapped** squeeze, or a 48 px
  control would land at 42 pt on a 2.95× phone.
- **Shape decides width, the squeeze decides everything inside it.** In portrait a
  panel takes 94 % of the canvas (not 100 — the scrim is how every one of these is
  dismissed); in landscape it keeps its authored width. Aspect, never a pixel
  width (§3.5).
- **New convention with teeth**: a plain `BoxContainer` in an overlay is *a row
  that stacks in portrait*; an `HBoxContainer` is a row that never does (the two
  shop tabs). Five rows were retyped for it — settings' palette/account/confirm
  rows, the gate's Continue/Back, the Start-over pair, and the pack row built in
  code. It has to be a plain `BoxContainer` because Godot refuses `set_vertical()`
  on `H/VBoxContainer` — the same trap BL-21 hit with the palette body.
- **Baselines live in node metadata**, captured lazily the first time a control is
  walked, so `apply()` is idempotent, nothing has to remember what anything was
  authored at, and the pack shop — the one overlay whose rows are *built* — only
  has to call `apply()` again after `set_packs()`.
- **The email**: `AUTOWRAP_ARBITRARY` in portrait, not word wrap. An address has no
  spaces, so word wrapping leaves one line whose minimum width is the whole
  address — at 2.4× that is wider than the panel, and the label would push the
  panel off the screen instead of clipping. Breaking mid-address is ugly and shows
  every character; showing every character was the requirement.
- Gotchas: a `ScrollBar` is a `Range` and would have taken the 130 px touch floor
  down the side of the pack shop (they are internal children so the walk never
  reaches them — the guard is belt to that pair of braces); and
  `OverlayMetrics.attach()` applies as it enters the tree, i.e. *before* the caller
  can connect `applied`, so the two panels that reflow their own content ask again.
- **Residual, honest**: (1) the squeeze reads `screen_get_scale()` for the
  device-pixel ratio, which Godot implements on Web/iOS/Android/macOS and returns
  1.0 for elsewhere — correct for every platform this ships to, and clamped to 4×
  so a bad reading cannot explode the layout; a dev hook,
  `OverlayMetrics.debug_squeeze`, forces a phone's 2.95× on a desktop box (the same
  pattern `SafeArea.debug_insets` is). (2) **Nothing here can move the mobile-web
  virtual keyboard**: Godot's web `LineEdit` does not scroll the focused field
  above the on-screen keyboard, so on a short phone the password field can still be
  covered while typing. What BL-48 fixes is that the field is now 44 pt tall and
  full-panel-width instead of 19 pt — engine-level scroll-into-view is not
  reachable from GDScript. (3) The panels are not scrollable: if a future overlay
  grows past the canvas height in portrait it will overflow rather than scroll.
- Smokes: **shell 158 → 199** (check i — desktop unchanged first, then a real
  720×1280 window with a phone's squeeze forced on, across all five overlays: panel
  width fraction, the 44 pt floor measured back into points, the stacked rows, the
  email wrapping with room to draw every pixel of itself, a row built in code
  scaled too, and the desktop restored afterwards) and **mobile 141 → 156** (the
  same shape at the squeeze a 720×1280 window really produces — no override — plus
  the Start-over confirm and the landscape "back to 1.0" assertion). paint 97, flow
  258, dlc 131 unchanged. `palette_smoke` is 239/241 standalone on this branch and
  241/241 when `flow_smoke` runs it as a child process — **pre-existing**, verified
  identical on the tree before this change, and it is the known windowed-focus
  flake ("a press on a docked crayon still raises it").
- Affected: `overlay_metrics.gd` (new), `settings_panel.{tscn,gd}`,
  `adult_gate.{tscn,gd}`, `account_panel.{tscn,gd}`, `pack_shop.{tscn,gd}`,
  `coloring_page.{tscn,gd}` (Start-over confirm only), `main.gd` (gear + More
  books), `shell_smoke.gd`, `mobile_smoke.gd`, DESIGN.md §3.5.

## Completed — archived

Full entries with as-built notes live in [BACKLOG_ARCHIVE.md](BACKLOG_ARCHIVE.md):

- **BL-1** — Default canvas zoom is too tight
- **BL-2** — Color picker slide-to-select
- **BL-3** — Brush size slider bar
- **BL-4** — Real page-curl flip; no auto-flip on completion
- **BL-5** — Tighter completion thresholds
- **BL-6** — Auto-save + manual save button
- **BL-7** — Start-over button per page
- **BL-9** — Coyote book display/mask split (one page, optional mask)
- **BL-10** — Free play: no completion gates + the coloring lock
- **BL-11** — Transient on-page celebration; BookComplete screen removed
- **BL-12** — Optional mask rendered as a layer under the detail image
- **BL-13** — App-branded splash screen, web loading shell, generated app icon
- **BL-14** — Wider brush-size range on the slider
- **BL-15** — Pick preview bubble + always-visible selection states
- **BL-16** — Pick feedback round 2 (chip removed, bigger bubble, louder states)
- **BL-17** — Undo / redo (stroke-recipe replay)
- **BL-18** — Erasure survives cloud sync: a wipe is a stamped instant that wins
  the merge (shelf + per-page clocks, two DELETE routes, dashboard wipe)
- **BL-19** — Web DLC download stall fixed (browser fetch hides 302s; web follows, native reads)
- **BL-20** — Child/Adult split removed — one crayon palette
- **BL-21** — Landscape: crayons dock beside the canvas
- **BL-22** — Crayon intensity ladder (light→dark, derived)
- **BL-23** — Fun crayon sets (superseded by BL-35's finish boxes)
- **BL-24** — Web authoring: book/page CRUD + server-side mapping + one-button publish
- **BL-25** — All books served by the server; release builds ship none
- **BL-26** — Client-side delta pack updates (fetch only changed files, zip fallback)
- **BL-27** — Splash auto-advances to the shelf (animated beat, tap = skip)
- **BL-28** — Bookshelf makeover: playroom wall + planks; cells drawn as real books
- **BL-29** — Toolbar crayon styling + save/start-over/undo-redo feedback
- **BL-30** — Book-open/close transition; richer page-curl (arc, shading, settle)
- **BL-31** — Crayon wax-stroke download animation in the pack shop
- **BL-33** — Landscape column shows every crayon (dynamic sizing + ranks, no scroll)
- **BL-34** — Cycle-left / cycle-right bars at the strip's ends (+ box-name flash)
- **BL-35** — Crayon boxes round 2: same lineup, escalating bakeable finishes
  (glow / grain / glitter). Animated finishes are BL-38.
- **BL-36** — Sticker sets: the cycle ring keeps going past the last crayon box
- **BL-37** — Sticker packs served by the API server (the manifest learns a content kind)
- **BL-38** — Animated crayon finishes (Shimmer, Twinkle) — the effect-mask channel,
  a second SubViewport saved as a second PNG
- **BL-32** — Web HTTPRequest "hang on Edge 151" — resolved as environmental:
  real browsers are fine; the hang only exists under the claude-in-chrome
  automation extension
- **BL-39** — Admin authoring screens restructured (list + editor pages, confirm
  modals, modified/last-published columns)
- **BL-40** — Artist book covers (manifest `cover`; shelf grid + open/close
  animation wear it, page 1 stays the fallback)
- **BL-41** — Animated stickers (sprite-sheet PNG + manifest
  `anim {hframes, vframes, frames, fps}`; absence = still)
- **BL-42** — Stickers peel off the canvas (tap → badge → peel; first-class
  history entry, sync-safe)
- **BL-43** — Bookshelf grid fills from the top-left
- **BL-44** — Shop tabs: coloring books | sticker sets
- **BL-45** — Palette: cycle bar un-stacked from the intensity tile (bottom-row
  tool band was vertical)
- **BL-46** — Start over is a soap-wash shader (`PageWash`), not a flash
