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
- **BL-27** — Splash auto-advances to the shelf (animated beat, tap = skip)
- **BL-28** — Bookshelf makeover: playroom wall + planks; cells drawn as real books
- **BL-29** — Toolbar crayon styling + save/start-over/undo-redo feedback
- **BL-30** — Book-open/close transition; richer page-curl (arc, shading, settle)
- **BL-31** — Crayon wax-stroke download animation in the pack shop
