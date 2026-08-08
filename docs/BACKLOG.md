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
