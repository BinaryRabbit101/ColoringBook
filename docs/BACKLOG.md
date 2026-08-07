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


### BL-27: Splash goes straight to the shelf — `open`
Playtest feedback (2026-08-07): the title screen's "tap anywhere to start" is a
gate with nothing behind it — the tap adds a step, not a choice. When the app
has finished loading, the splash should play a short, joyful beat (crayons
settling, title flourish) and then carry the player straight to the bookshelf
with no tap required. The title screen keeps its role as the loading face of
the app; it loses its job as a door.
- Affected: `scripts/main.gd` (screen flow), `scripts/screens/title_screen.gd`,
  `scenes/screens/title_screen.tscn`

### BL-28: The bookshelf should look like a bookshelf — `open`
Playtest feedback (2026-08-07), two halves of one picture:
1. **The room.** The shelf screen is a grid of cards floating on a flat solid
   colour. It should feel like a cosy corner of a playroom — warm background,
   visible shelves the books stand ON, colour and depth instead of flatness.
2. **The books.** Each `BookCell` is a rounded card. It should read as an
   actual coloring book: a cover with a visible spine, a hint of stacked page
   edges down the open side, sitting on the shelf — not a UI card.
Both stay primitive-drawn (no PNG art) per the existing component style.
- Affected: `scripts/screens/book_select.gd`, `scenes/screens/book_select.tscn`,
  `scripts/components/book_cell.gd`

### BL-29: Page toolbar polish + action feedback — `open`
Playtest feedback (2026-08-07): the buttons across the top of a coloring page
are plain, and the big verbs give no ceremony:
1. **Toolbar look.** The top-of-page buttons (back, prev/next, save, start
   over, undo/redo, padlock) should be fun and colorful — crayon-adjacent
   styling consistent with the palette, still touch-sized (DESIGN.md 3.5).
2. **Save** should answer with a small delightful animation, not just the
   "Saved!" text.
3. **Start over** should feel like a fresh page — e.g. a wipe/sweep as the
   paint clears.
4. **Undo / redo** should visibly respond on press (pop, wiggle, brief sparkle
   as the stroke vanishes/returns), so the buttons feel connected to the paint.
- Affected: `scripts/screens/coloring_page.gd`,
  `scenes/screens/coloring_page.tscn`, `scripts/components/history_button.gd`,
  `scripts/components/padlock_button.gd`

### BL-30: Opening a book, and a richer page flip — `open`
Playtest feedback (2026-08-07):
1. **Opening.** Tapping a book on the shelf currently hard-swaps to the
   coloring screen. It should feel like opening a book — a cover-opening /
   zoom-toward-the-book transition between shelf and page.
2. **Flipping.** The BL-4 page-curl works but is visually plain; give the curl
   more life (paper shading, a settling bounce, maybe a soft page-turn arc)
   while keeping its role — the flip is the reward for finishing a page.
- Affected: `scripts/main.gd` (screen swap), `scripts/components/page_flip.gd`
  (visuals only — the flip's API and its trigger in `coloring_page.gd` stay)

### BL-31: Downloads should be fun to watch — `open`
Playtest feedback (2026-08-07): downloading a book pack in "More books" is a
bare progress bar. A child (or grown-up) waiting on a download should get
something playful — e.g. a crayon filling the bar with a wax stroke, a little
book assembling page by page, colors marching. Keep the real progress data
(bytes, ratio) driving the animation; keep the existing error/status text.
- Affected: `scripts/components/pack_shop.gd` (PackRow visuals)

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
- **BL-23** — Fun crayon sets (Pastel, Neon, Earth, Candy, Spooky)
- **BL-24** — Web authoring: book/page CRUD + server-side mapping + one-button publish
- **BL-25** — All books served by the server; release builds ship none
- **BL-26** — Client-side delta pack updates (fetch only changed files, zip fallback)
