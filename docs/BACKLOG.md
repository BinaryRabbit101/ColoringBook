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

### BL-50: A page saved on one device never appeared on the other — `done` (2026-08-08)
Playtest report: *"I'm logged in and saved my page canvas, yet when I logged in on
another device, I didn't see my previously saved page. Both apps were continuously
running without a refresh/restart."*

**The picture was never missing. It was on the second device's disk, underneath a
blank canvas.** The pull works and always did: signing in drains and pulls
progress, opening a book pulls that book's paint, `install_page_paint` writes the
PNG. What nothing did was tell the screen. `ColoringPage._apply_current_page()`
reads the paint layer off disk once, at page load, some hundreds of milliseconds
before the download lands — and then never looks again. So the child sat in front
of blank paper with the drawing already in `user://paint/`.

**And it got worse from there.** `_has_nothing_to_persist()` is "untouched AND no
file"; the pulled file makes the second half false, so the next save point read the
blank canvas back, wrote it over the picture and uploaded it — stamped *now*, which
wins last-write-wins. The bug did not just fail to show device A's drawing on
device B; leaving the page **destroyed it on the server**, and device A then pulled
the blank over its own copy. Nobody hit that in the report because they never left
the page, but it was one Back press away.

Three parts, none of them a new sync concept:

1. **`GameState.page_paint_installed`** — a second signal, emitted by
   `install_page_paint` and by nothing else. `page_paint_written` means "a file
   this device caused"; the new one means "a picture you did not draw is now on
   disk", which is the only case a screen has anything to do about.
   `SyncQueue` ignores it: it is the thing that wrote the file.
2. **`ColoringPage` adopts it** (`_on_page_paint_installed` → `reload_saved_paint`)
   when it is the open page and the visit has nothing of its own to lose — no
   unsaved strokes, no stroke down, no replay, no restore, no flip. The canvas is
   **cleared and rebuilt**, never composited over: the layer on screen and the file
   are two pictures of the same page, not an update of one another, so drawing the
   new over the old would leave the old showing wherever the new is transparent.
   A page that arrives finished sets `_pre_completed` through the existing
   `_restoring` branch, so it does not celebrate somebody else's colouring.
   If the child *is* drawing, the screen keeps the canvas and wins the next
   last-write-wins round with it — 8.2's "no response ever yanks a screen" is the
   rule, and refusing is what keeps it true.
3. **The persist guards** — `_persist_page` refuses while a restore is in flight and
   `_persist_page_async` waits it out (`_await_restore`, the twin of
   `_await_replay`). That closes the Back-pressed-mid-download window that was the
   data-loss half.

Plus the two the report's "both apps running" shape needs:

- **`SyncQueue._wants_server_paint` no longer refuses the open page outright.** The
  resume page **is** the open page by construction — `start_book` sets the cursor
  *before* it emits `book_started`, which is what runs the pull — so the blanket
  refusal meant a device that had already synced a page could never receive a newer
  copy of the one page a child looks at first, on any device, ever. It now refuses
  only when the two digests disagree, i.e. when this device holds pixels the server
  has not got. A copy the server has acknowledged is safe to replace, and part 2
  puts it on screen. (Only the *no local file* branch used to get through, which is
  why check (i) passed while the bug was live.)
- **`SyncQueue.on_signed_in` pulls the open book's paint** after its drain. The app
  on this device has been running the whole time; "pulled on book open" already
  fired for the book the player is in, back when there was no account to pull for.

**Not changed, deliberately.** The resume *cursor* still refuses to move under an
open book (`set_saved_page_index`) — turning the page under a colouring child is
the same failure this entry is fixing in the other direction. And the shelf needs
no refresh signal: `BookCell` draws a cover and a page count, never progress.

**No server change, no migration.** The endpoints, the merge and the payloads are
untouched; every line of this is client-side.

- Verified against a local `php artisan serve --port=8123`:
  **flow 256 → 270/270** (new check 4d: the picture is adopted by the OPEN page
  with no restart, pixel for pixel; a page that arrives finished does not
  celebrate; the next save point writes the picture back rather than the blank
  paper it replaced; and a second picture arriving while the child is drawing is
  refused). **sync 131 → 135/135** (check (i) extended: device B saves a NEWER
  picture for the page device A has open, A's next book open pulls it, and it is
  not pushed straight back). paint 97, shell 158, mobile 141, dlc 131 — all
  unchanged and green. Not run: palette (touches nothing here; the known
  windowed-focus flake).
  The web build was NOT used to verify any of this — the claude-in-chrome
  extension hangs Godot's `HTTPRequest` in a driven browser (BL-32).
- Affected: `godot/autoload/game_state.gd`,
  `godot/scripts/screens/coloring_page.gd`,
  `godot/scripts/backend/sync_queue.gd`, `godot/scripts/dev/flow_smoke.gd`,
  `godot/scripts/dev/sync_smoke.gd`

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
