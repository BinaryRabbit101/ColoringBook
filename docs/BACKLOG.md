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
- Affected: `server/` (Laravel app in this repo), `docs/DLC_SERVER.md`,
  `docs/SERVER_BUILD_PLAN.md`

### BL-18: "Erase all progress" must survive cloud sync — `open`
Surfaced by the WP11 sync client (2026-08-06). "Erase all progress" (and the
per-page "Start over", BL-7) is local-only, but against a synced account the
§6.3 merge rule only ever climbs: the next pull quietly restores everything
from the server, so the erase appears not to work. That is the merge doing its
job — a save must never lose to a network race — but a grown-up pressing the
button expects it to stick. Options, not mutually exclusive:
1. **Server-side wipe from the parent dashboard** (the clean answer): delete
   the account's/profile's `book_progress` + paint rows there, where the adult
   already is; the device's next pull then has nothing to restore. Needs a
   deliberate "device pushes right back" answer — the client should reset its
   sync-queue fingerprints/revisions when it erases locally, or its next drain
   re-uploads the erased state.
2. **Client "erase and stop syncing"**: local erase also signs the device out
   (or pauses sync) so the restore never fires — cheap but surprising in the
   other direction.
Per-page "Start over" has the same shape in miniature: the erased page's paint
is deleted locally, but the server's copy wins the next LWW comparison unless
the deletion is pushed as a state (tombstone or explicit delete endpoint —
DLC_SERVER.md §11 currently has none).
- Affected: server (dashboard wipe UI + a paint/progress delete or tombstone
  path), `scripts/backend/sync_queue.gd` (fingerprint/revision reset on local
  erase), docs/DLC_SERVER.md §6.3/§11
- Decision needed before paint/progress sync ships to a real household.


### BL-32: Web build — HTTPRequest hangs on Chromium/Edge 151 — `open`
Found 2026-08-07 during the BL-25/BL-26 live verification. On Edge 151
(Chromium), **every** Godot `HTTPRequest` in the web build hangs after the
response arrives: the browser completes the request (200/401 visible in the
network log), but `request_completed` never fires — no result, no timeout —
so the shop sits at "Looking for new books…" and sign-in at "Contacting the
server…" forever. **Not caused by any of this repo's code or the server**,
proven three ways:
1. Yesterday's known-good build (commit 5423037, verified working in-browser
   2026-08-06) now hangs identically against the live server.
2. The same old build hangs identically against a plain local `php -S`
   file server (a bare 404 response — no nginx, no proxy, no API).
3. Page-level JS in the same tab is fine: `fetch()` + `body.getReader()`
   completes in ~150 ms with the full body and `done: true`, and the
   `transfer-encoding: chunked` header IS exposed (so the glue's chunked
   detection isn't the break).
The engine binary is the stock 4.5.1 web template both days; the browser
auto-updated to 151 in between. Precedent: Chromium 113 broke Godot HEAD
requests the same way (godotengine/godot#76825). Not yet filed upstream for
151 as of 2026-08-07.
- Caveats: reproduced only under the claude-in-chrome automation extension in
  Edge 151 — **first step is a hand test in a human-driven browser** (phone
  Safari, Chrome, Firefox) to separate "Chromium 151 broke it" from
  "extension interference". Native (desktop) API traffic is fully green
  (backend 180 / sync 87 smokes against the real server).
- Options if confirmed browser-wide: newer export templates (4.5.2+/4.6) if
  upstream fixes it; file the upstream issue with the §3 evidence; or a
  JS-bridge workaround in the web shell (heavy — last resort).
- Affected: web export only; blocks sign-in/downloads/sync in affected
  browsers. The game itself (shelf, coloring, saves) runs fine there.


### BL-33: Landscape column must show every crayon — no scrolling — `open` (2026-08-07)
Playtest: on a horizontal display the docked crayon column scrolls; every crayon
must be visible at once, no scrollbar. BL-21 shipped that scroll as a known
trade ("a BL-23 set can be any length") — this entry reverses the trade for the
shipped lineup. Direction:
- Size crayons dynamically: available strip length ÷ crayon count, clamped at
  `CrayonButton.MIN_TOUCH_TARGET` (the 64 px floor is non-negotiable —
  DESIGN.md §1).
- If a set cannot fit at the floor (a long authored set on a short canvas),
  wrap to a second rank inside `STRIP_THICKNESS` (212) rather than scroll —
  scale the whole crayon down so two ranks fit, or widen the strip for the
  column case only. Agent decides with smoke evidence; scrolling is the one
  outcome that's off the table.
- Portrait row gets the same treatment for free if it falls out naturally, but
  landscape is the acceptance bar.
- Coordinates with BL-34: the cycle arrows land at the strip's ends, which
  changes what length is actually available to the crayons. Do BL-34 first or
  together.
- Acceptance: shipped ten-crayon lineup + both tool tiles fully visible in the
  landscape column at the smallest supported canvas, zero scroll; palette
  smoke gains fit checks in all layouts.
- Affected: `scripts/components/palette_child.gd`, `crayon_button.gd`,
  `scenes/components/palette_child.tscn`, palette smoke.

### BL-34: Cycle-left / cycle-right arrows at the strip's ends — `open` (2026-08-07)
Replace the single `CrayonBoxButton` (forward-only cycle) with a cycle-left and
a cycle-right control sitting at the OUTER ends of the crayon strip — outside
the crayons, one at each end of the long axis.
- `PaletteDef.wrap_crayon_set()` already wraps; add the backward direction
  (wrap negative) and a `prev_crayon_set()` beside `next_crayon_set()`.
- Both arrows stay OUTSIDE the `ScrollContainer` so a slide-to-select can never
  land on one (the BL-2/BL-23 rule, preserved).
- This deliberately reworks the tool-tile geometry the smokes guard ("two 88 px
  tiles share the strip's short axis; a third overflows silently"): arrows move
  to the long-axis ends, freeing short-axis room. `IntensityButton` stays where
  it is. Rewrite the tile-fit smoke checks around the new geometry rather than
  contorting to keep the old ones green.
- Decide where the current box's identity lives now that the tile that drew it
  is gone: pips under an arrow, a transient box-name label on cycle (nice —
  says "Neon!" as the strip swaps), or both.
- Affected: `palette_child.gd`, `crayon_box_button.gd` (reshaped into arrow
  buttons or replaced), `palette_def.gd`, palette smoke tile-fit block.

### BL-36: Sticker sets — the cycle keeps going past crayons — `open` (2026-08-07)
Cycling past the last crayon box lands on sticker sets: the strip swaps crayons
for a row of stickers, tap the page to place one. Decisions to settle in
design, then build:
- **Placement layer**: stickers sit ON TOP of the page (above line art) — they
  are stickers, not paint. Not region-clipped, never counted toward coverage.
- **Fun by default**: slight random rotation on placement, a satisfying
  plop/settle animation; sticker size proportional to the page.
- **Palette contract**: the strip's contract today is `color_picked` +
  `brush_size_picked` and nothing else reaches the paint path. Sticker mode
  adds a surface (e.g. `sticker_picked(texture)` + a mode signal) —
  `ColoringPage` opts in; `PageView` painting stays untouched. Entering sticker
  mode disables stroke painting until a crayon box is cycled back.
- **History**: placing a sticker is an undoable entry in BL-17's stacks
  (placement list, not paint pixels); removal = undo, plus optionally a
  peel-off gesture later.
- **Persistence**: a per-page sticker list in the save (additive key beside
  `status`/`locked`, reader tolerates its absence — same trick as BL-10's
  entry upgrade), and the paint-layer sync (BL-8/WP11) carries it.
- **Discovery**: `StickerSetDef.discover()` scans installed packs under
  `user://dlc`, mirroring `BookDef` post-BL-25 — sticker sets are SERVER
  content, see BL-37. The repo keeps dev-fixture sets for smokes only
  (excluded from release exports like `resources/books/*`). Art: start with
  primitive-drawn or emoji-style shapes; real art flows through the BL-37
  authoring pipeline.
- Depends on BL-34 (the cycle ring is what grows); independent of BL-35.
- Affected: new `sticker_set_def.gd` + assets, `palette_child.gd` (mode +
  cycle ring), `coloring_page.gd` (placement, history, save points),
  `game_state.gd` (save shape), a new sticker layer component over `PageView`,
  DESIGN.md, palette/flow smokes.

### BL-37: Sticker packs served by the API server — `open` (2026-08-07)
Sticker sets are catalog content, delivered exactly like coloring books
(BL-25 rule: release builds ship none; the server serves everything):
- **Pack format**: the same data-bundle shape as book packs (DLC_SERVER.md
  §7.1–7.2) — the manifest gains a content `kind` (`book` today; add
  `sticker_set`), files are the sticker images + the set definition. Delta
  updates (BL-26) apply unchanged: they diff the manifest's file hashes and
  never cared what the files are.
- **Server**: catalog rows carry the kind; the BL-24 web-authoring dashboard
  grows a sticker-set CRUD (name, sort order, upload sticker images,
  thumbnails) with the same one-button publish. No headless-Godot mapping
  step — stickers have no regions; validation is image checks only, so the
  publish path is strictly simpler than a book's.
- **Delivery**: same catalog/entitlement/download endpoints (§7.4, §11).
  Free sticker packs ride the free-entitlement path; paid waits for Phase 6
  like everything else.
- **Client**: `StickerSetDef.discover()` scans installed packs under
  `user://dlc` (mirroring `BookDef` post-BL-25); `pack_installer.gd` learns
  the new kind — mostly *stops assuming every pack is a book*; the shop lists
  sticker packs beside books with the kind visible on the card.
- Repo keeps dev-fixture sticker sets for the smokes, excluded from release
  exports exactly like `resources/books/*` (the BL-25 preset rule).
- **Seed content**: ship a small FREE "Starter Stickers" pack with the feature
  (mainly for testing) — roughly 6–10 simple crowd-pleasers (stars, hearts,
  smiley, rainbow, balloon, paw print…), primitive-drawn or emoji-style art is
  fine. Published to the dev server (mini-pc) as a free entitlement the moment
  the server half lands, so hand-testing downloads a real pack end-to-end; it
  doubles as the reference pack the authoring UI and delta updates are
  exercised against. It can share art with the repo's smoke fixtures, but the
  shipped copy comes from the server like everything else.
- Depends on BL-36 for the client feature it feeds; the server half can start
  as soon as BL-36 pins the set-def and save shapes.
- Affected: `server/` (catalog-kind migration, authoring UI + publish, API),
  `docs/DLC_SERVER.md` §5/§7/§10/§11, `scripts/backend/pack_installer.gd`,
  `sticker_set_def.gd` discovery, backend/dlc smokes.
### BL-38: Animated crayon finishes — phase 2 of BL-35 — `open` (2026-08-07)
BL-35 shipped the **bakeable** half of the finish ladder (classic wax → neon
glow → textured wax → glitter): every finish is computed in `brush.gdshader` at
stamp time, so it is flattened into the paint SubViewport and the saved PNG
carries it for free. The finishes that have to keep MOVING after the stroke is
down — a shimmer that travels, glitter that twinkles — are what is left.
- **The seam already exists.** `BrushFinish.is_animated(id)` is false for every
  shipped finish and is the thing to branch on; the palette already resolves a
  finish per box and hands it to the paint path on `brush_effect_picked`, and
  `PageView.brush_effect` already carries it into every stamp and every BL-17
  recipe. An animated box is a new entry in `BrushFinish.FINISHES` plus whatever
  answers the question below — no reshaping of any of the above.
- **The open question is PERSISTENCE, and it is the whole entry.** A live effect
  cannot live in the flattened paint layer: it needs either an effect-mask
  channel rendered beside the paint (a second SubViewport, sampled by a display
  shader, saved as a second PNG) or per-stroke metadata that survives save and
  restore — and BL-17 recipes are per-visit only today, cleared on navigation and
  never written to disk. Answer that first; the shading is the easy half.
- Constraints that do not move: region clipping still owns every finish (an
  animated glow is still discarded outside the locked region's id), coverage and
  completion must not see the animation, and a page reopened must look the way it
  looked when it was closed.
- Affected: `scripts/components/brush_finish.gd`, `scenes/components/brush.gdshader`,
  `page_view.gd` (a second layer, if that is the answer), `game_state.gd` (save
  shape), `coloring_page.gd` (restore), paint/flow smokes.

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
- **BL-35** — Crayon boxes round 2: same lineup, escalating bakeable finishes
  (glow / grain / glitter). Animated finishes are BL-38.
