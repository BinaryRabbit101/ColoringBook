# Server Build Plan — Laravel app (`server/`)

Implementation campaign for [DLC_SERVER.md](DLC_SERVER.md) Phases 1–5. This doc is the
working brief for the implementation agents; DLC_SERVER.md remains the design authority —
where this doc is silent, the design doc rules.

## Decisions (2026-08-06, supersede the design doc where they conflict)

| Topic | Decision | Design doc said |
|---|---|---|
| Location | `server/` inside the game repo | sibling app `coloringbook-api` |
| Database | **SQLite** (house pattern, one file per site) | MySQL |
| Dashboard/admin UI | **Inertia v3 + Vue 3 + Fortify** (house pattern, per `Reminders`) | Blade + Livewire |
| Game-client auth | Laravel **Sanctum** bearer tokens with abilities — unchanged | same |
| Scope | Phases 1–5; **no payments** (Phase 6 later) | — |
| Child profiles (Q4) | ~~**In v1.** Schema ships `child_profiles`; sync payloads carry optional `profile`~~ — **superseded 2026-08-09**, see below | open |
| `age_band` (Q12) | **Not collected.** Nothing about a child is stored anywhere | proposed |
| Email (Q11) | `MAIL_MAILER=log` for now; password reset works but mails go to the log. SMTP relay is a deploy-time concern. Since 2026-08-09 the only person who can receive one is the operator | open |
| `X-Accel-Redirect` (§7.4) | Behind config `coloringbook.accel_redirect` (default off). Off = stream via PHP `Storage::download` — correct in dev, flip on under Nginx | — |

## Decisions (2026-08-09 — the device-only identity)

**These supersede DLC_SERVER.md's account and save-sync sections and the 2026-08-06 row on
child profiles.** The product call: manual registration and login are gone, and with them
every reason for a player's data to exist on a server. `server/CLAUDE.md` restates this for
implementing agents; where any doc still describes parent accounts, child profiles or cloud
save-sync, that file and this table win.

| Topic | Decision | Superseded |
|---|---|---|
| Player identity | **The `Device` row IS the identity.** Sanctum tokens are minted on `Device` (it is `Authenticatable` + `HasApiTokens`), so `$request->user()` is a `Device` on every game route | accounts, WP1's `POST /auth/*` |
| `users` | **Operators only** — the person who signs in to publish packs. `is_admin` is the whole model; rows come from a seeder or a shell, and there is no registration route in the app | "guardian registers" |
| Entitlement owner | `entitlements.device_id`, and nothing else. `App\Services\EntitlementOwner` deleted | `entitlements.user_id` / dual owner |
| Restore purchases | **Re-verify the same store receipt from the new device.** Hence `UNIQUE(device_id, platform, platform_txn_id)` rather than a global one — the same receipt legitimately grants on N devices, which Google Play requires | account linking / adoption |
| Cloud saves | **Gone.** No `book_progress`, `paint_layers`, `retained_paint_layers`, `shelf_erasures`; no `/sync/*`, no `PaintStorage`, no `paint` disk, no `paint:prune` schedule. `user://` is the whole persistence story | design §6 in full, WP2 + WP4 |
| Abilities | Exactly `entitlements:read` + `packs:download`. **`save:sync` no longer exists anywhere** | three abilities |
| `/device/register` | Contract unchanged and **pinned**: `{device_uid, device_name, platform}` → `{token, abilities, expires_at, device:{ulid}}`, `throttle:6,1`. `devices.device_uid` is now globally unique — there is no account to scope it inside | `user_id IS NULL` scoping |
| Token refresh | **No refresh route.** A `401` is recovered by re-registering with the same uid; find-or-create makes it idempotent and the entitlements survive | `POST /auth/refresh` |
| Web surface | `/admin/*`, `/login`, `/dashboard`, `settings/{profile,security,appearance}` — admin session only. Removed: `settings/{profiles,devices,pictures,progress}`, `DELETE settings/profile`, the passkey well-known, and Fortify's register / email-verification / two-factor / passkey routes | parent dashboard |
| Admin grants | `POST /admin/entitlements` addresses a **`device_uid`** — the only handle a player has — and answers `DEVICE_NOT_FOUND` instead of `USER_NOT_FOUND` | grant by email |
| Migrations | **Squashed into the original `create_*` migrations** rather than added as a drop round. Nothing is deployed that would need the intermediate states | — |
| PII | **Players have none.** The operator's email is the only address stored, and nothing a child makes leaves the device. Update any COPPA discussion to that footing | "a parent's email" |

Client half (`godot/`), for the record, since the two move together: `sync_queue.gd`,
`account_panel` and the sync smoke are deleted; `auth.json` is schema **v2** and device-only
(a v1 file keeps its `device_uid` and drops the rest); `Backend.sign_in_device()` runs at
startup, `_authed()` replays a request once after re-registering on a `401`, and
`restore_purchases()` / `get_store_receipts()` are the billing-plugin seam. The `AdultGate`
now guards money instead of accounts, and settings' Account row is **Purchases → Restore**.
`user://sync_queue.json` is orphaned on disk: nothing reads or writes it.

## House conventions (copy from these, don't invent)

- **Reference apps:** `C:\Users\binar\Documents\websites\Reminders` (newest scaffold) and
  `C:\Users\binar\Documents\websites\StoryCampaign` (most complete). Match their
  `composer.json` shape: Laravel `^13`, PHP `^8.3`, Inertia v3, Fortify, Wayfinder,
  Tinker; dev: Pint, Larastan, Pail, **Pest v5**, Sail.
- Frontend: Vue 3 + TypeScript + Vite, eslint + prettier configs copied from Reminders.
- `pint.json`, `phpstan.neon`, `.editorconfig`, `.prettierrc` copied from Reminders and
  adjusted only if paths differ.
- Composer scripts: keep `setup`, `dev`, `lint`, `lint:check`, `types:check`, `ci:check`,
  `test` exactly as in Reminders — `composer test` must run pint-check + phpstan + pest.
- App-layer layout follows StoryCampaign: `app/Actions`, `app/Services`, `app/Models`,
  domain logic out of controllers.
- IDs: numeric autoincrement PKs internal; every row that crosses the API boundary gets a
  `ulid` column and is addressed by it (design doc §5).
- API error shape everywhere: `{"error": {"code": "SNAKE_CASE", "message": "…"}}`.
- Routes: `routes/api.php` holds no routes of its own — it only `require`s the per-domain
  files (`routes/api/device.php`, `catalog.php`, `admin.php`) under the `/api/v1` prefix, so
  parallel agents never edit the same route file. Add routes to your domain file.

## Work packages

> **These are the campaign record, not a brief to work from.** They are left as
> written — including WP1's accounts and parent dashboard, WP2's progress sync, WP4's
> paint sync and WP11's sync client — because the acceptance criteria and the
> conventions they established are what the app was built against. Where a work package
> below conflicts with the **2026-08-09 Decisions** table, the table wins and the work
> package is history: none of that machinery still exists.

### WP0 — Scaffold (sequential, blocks everything)

- `laravel new` Vue starter kit (or manual composer create matching Reminders), at
  `server/`, SQLite, Pest.
- Install Sanctum + API routes; create the empty per-domain route files.
- `users` migration: add `ulid`, `is_admin`. Fortify enabled for web session auth.
- `config/coloringbook.php`: `accel_redirect`, storage paths, token TTL (90 d sliding),
  min pack version knobs.
- Storage disks: `packs`, `assets`, `paint` under `storage/app/private/` per §5.
- `server/CLAUDE.md`: stack summary, run/test commands, pointer to DLC_SERVER.md + this plan.
- Root repo `.gitignore` untouched; starter kit's own `.gitignore` covers
  `server/vendor`, `server/node_modules`, `server/database/*.sqlite`.
- **Acceptance:** `composer test` green on the fresh scaffold; `php artisan serve` boots;
  starter-kit login/register pages render.

### WP1 — Accounts, auth, parent dashboard (sequential, after WP0)

Design §4, §5 "Accounts", API §11 Auth + Profiles.

- Models + migrations: `child_profiles` (ulid, user_id, nickname, avatar_index,
  default_mode), `devices` (ulid, user_id, device_uid unique-per-user, device_name,
  platform, last_seen_at).
- Registration requires `is_guardian: true` confirmation; email + password is the whole
  PII footprint.
- API: `POST /api/v1/auth/register`, `POST /auth/token` (device-scoped Sanctum token,
  abilities `save:sync`, `entitlements:read`, `packs:download`; 90-day sliding expiry),
  `POST /auth/refresh`, `DELETE /auth/token`, `GET /me`. Profiles CRUD per §11.
  `throttle:6,1` on auth, `throttle:60,1` on the rest.
- Parent dashboard (Inertia pages): profiles CRUD, device list + revoke token, account
  deletion (hard delete, cascades profiles/progress/paint — password re-confirmation).
- **Acceptance:** Pest feature tests for every endpoint incl. ability enforcement,
  token expiry slide, device revocation, hard-delete cascade; `composer test` green.

### WP2 — Progress sync (wave 2, parallel with WP3)

Design §6, API §11 Sync (progress rows only — no paint).

- `book_progress` model + migration (§5), unique `(user_id, child_profile_id, book_uid)`.
- `GET /api/v1/sync/progress?profile=&since=`, batched `PUT /sync/progress` with
  `base_revision` optimistic concurrency → per-book `409` carrying server state.
- The merge rule (§6.3) as a pure `App\Services\ProgressMerge` class:
  per-page `max(status)` under `untouched < in_progress < complete`, max furthest,
  newer-`client_updated_at` wins `current_page_index`. Commutative + idempotent —
  property-style Pest tests proving replay safety.
- **Acceptance:** merge unit tests (incl. commutativity/idempotence), endpoint feature
  tests incl. 409-merge-retry flow, profile scoping.

### WP3 — Catalog, entitlements, DLC delivery (wave 2, parallel with WP2)

Design §5 Catalog/Entitlements, §7, API §11 Catalog & DLC. Free/promo entitlements only.

- Models + migrations: `packs`, `pack_versions` (immutable once published), `books`
  (`book_uid` unique stable), `pages` (nullable `mask_asset_id` — BL-9/BL-12), `assets`
  (content-addressed sha256), `entitlements` (unique user+pack, no expiry column).
- Endpoints: `GET /packs`, `/packs/{slug}`, `/packs/{slug}/manifest`,
  `/packs/{slug}/download` (302 → 10-min `temporarySignedRoute` → streamed file or
  `X-Accel-Redirect` per config), `/packs/{slug}/files/{path}` delta route,
  `GET /entitlements` (doubles as update check), `?client_version=` filtering on
  `min_client_version`.
- `php artisan pack:publish {dir}` — the Phase-5-until-then publisher: reads a built
  pack directory (manifest.json + files), validates, writes catalog rows + zip. This is
  also what tests use to seed a real pack.
- Manifest schema exactly §7.2 (`manifest_version: 1`, per-file sha256 map for deltas).
- **Acceptance:** feature tests for entitlement gating (401/403/`ENTITLEMENT_REQUIRED`),
  signed-URL expiry, sha256 integrity of served files, min_client_version filtering,
  publish-from-disk round trip.

### WP4 — Paint-layer sync (wave 3, after WP2, parallel with WP5)

Design §6.2–6.3 paint rows, API §11 paint endpoints.

- `paint_layers` migration (§5), storage at `paint/<user_ulid>/<book_uid>/page_NN.png`.
- `POST /sync/paint/{book_uid}/{page}` sha256 negotiation → `204` have-it / `202`
  upload; `PUT` raw PNG with `Content-Digest` verification → `201 {revision}`;
  `GET` → 302 signed URL / 404.
- LWW on `client_painted_at`, server-clock tie-break, reject >24 h future clocks.
  Losing version retained 30 days as `page_NN.<rev>.png`; scheduled prune command;
  dashboard "restore the older picture" per book/page.
- **Acceptance:** feature tests for the 204/202 negotiation, digest mismatch rejection,
  LWW incl. clock clamp, retention + restore, prune.

### WP5 — Admin upload / validation / preview / publish (wave 3, after WP3, parallel with WP4)

Design §10, API §11 Admin.

- Admin-only (`is_admin`) Inertia section + API: `POST /admin/assets` (content-addressed,
  idempotent), `POST /admin/packs`, `POST /admin/packs/{slug}/versions` (zip or
  manifest+ulids), preview route, publish, `POST /admin/entitlements` (promo grant by
  email).
- Validation per §10.1: dimension match, regions-JSON schema + `image_size` match,
  **JSON-ids ↔ idmap-colors bijection** (count both directions), `#000000` present,
  giant-region check (<~90 % of paintable pixels), `region_count > 0`. Pure-PHP (GD)
  in `App\Services\PackValidation`.
- Preview: composite random region tints under the display art (GD), served to the
  admin UI per page.
- **Acceptance:** validation unit tests with fixture PNGs (valid pair, mismatched pair,
  giant region), admin feature tests, end-to-end draft→preview→publish→visible-in-
  `GET /packs` test.

### WP6 — Integration pass (sequential, last)

- Merge all branches, run `composer test` + `npm run build` at root of `server/`.
- Boot the app, curl-smoke every §11 route group.
- Update DLC_SERVER.md §12 phase table + BACKLOG.md (BL-8 status), note deviations.

## Wave schedule (Opus agents)

| Wave | Agents | Isolation |
|---|---|---|
| 0 | WP0 scaffold — one agent (or main session) | in-place |
| 1 | WP1 — one Opus agent | in-place |
| 2 | WP2 ∥ WP3 — two Opus agents | git worktrees, merged after |
| 3 | WP4 ∥ WP5 — two Opus agents | git worktrees, merged after |
| 4 | WP6 integration — main session | in-place |

Every agent: read this doc + DLC_SERVER.md first; conventions from Reminders/StoryCampaign;
`composer test` must be green before reporting done; no edits outside `server/` except
WP6's doc updates.

## Campaign 2 — client integration, Dusk, first API-served book (2026-08-06)

Campaign 1 (WP0–WP6) built the server (since merged to `main`; the suite has
grown past 470 tests with later campaigns). Campaign 2 wires the game to it.

> **Status (2026-08-06): all of Campaign 2 is done.** WP7–WP12 complete: eight
> godot smoke suites green (paint 47, palette 112, flow 159, shell 147, mobile
> 139, dlc 90, backend 151, sync 87), Dusk 33 browser tests, coyote-book v1
> published and round-tripped, web build deployed to the port-91 site with live
> in-browser play verified. Known follow-ups: web save is slow (blocking
> readback — design call), the debug Test Book ships in the release build,
> dev smokes ride in the `.pck`, HTTPS on the mini-pc would remove two shell
> workarounds, and BL-18 (erase vs sync restore) needs a decision.
> *(Of those follow-ups, "the debug Test Book ships in the release build" was
> closed by BL-25 on 2026-08-07 — release exports ship no books at all.)*

### WP7 — Godot Phase 0 (client prep; no server dependency)

DLC_SERVER.md §6.1, §8.1 items 1–3, §12 Phase 0.

- `BookDef.book_uid` authored `@export` (`coyote-2026` for the coyote book);
  `book_key()` uses it; save schema v2 keyed by uid with a v1 migration
  (lookup table of known `res://` paths → uids) and one-time paint-dir rename
  (`book_slug()` hashes the uid).
- `BookDef.discover()` second root: `user://dlc/*/books/*/book.json` (§7.2
  shape) → in-memory `BookDef`/`PageDef` with `is_runtime`. **De-dupe by
  `book_uid`, built-in wins** — the DLC coyote pack deliberately shares
  `coyote-2026` with the built-in book.
- `PageView.load_page_textures(...)` primitive; `load_page()` becomes a thin
  wrapper. Runtime textures via `Image.load_from_file()` →
  `ImageTexture.create_from_image()` on a `WorkerThreadPool` task; the ID map
  keeps `TEXTURE_FILTER_NEAREST` and must never be VRAM-compressed.
- Prove with a hand-seeded pack in `user://dlc/` + a `dlc_smoke.gd` dev smoke
  following the existing `*_smoke.gd` patterns.

### WP8 — Dusk browser tests (server/)

- `laravel/dusk` (house version per Reminders), scaffold, chromedriver.
- Coverage: guardian register, login, child-profiles CRUD, devices revoke,
  account deletion, pictures restore, admin gating (non-admin 404, sidebar
  hidden), admin pack list/create/publish, entitlement grant.
- Separate `composer test:dusk`; the main `composer test` gate is untouched.

### WP9 — Coyote pack: build tool + first published pack

- `pack build` CLI (design §10.2): walks the coyote book's artifacts, emits a
  §7.2 pack directory (manifest.json, book.json, display/mask/idmap/regions
  per page), pack slug `coyote-book`, `is_free`, `book_uid` `coyote-2026`.
  GDScript headless or PHP — **not Python** (not on this box).
- Publish through `php artisan pack:publish`; verify by API round trip
  (entitle → manifest → download, sha256s match).

### WP10 — Backend client: auth, entitlements, pack install (Godot)
After WP7+WP9. Adult gate + sign-in, `user://auth.json`, entitlements check,
download to `user://dlc/<slug>.incoming/` + sha256 verify + atomic swap,
offline-first rules (§8.2). `Backend` facade over `RefCounted` classes (Q3).

### WP11 — Sync client (Godot)
After WP10. `sync_queue.json`, progress push/pull + client-side merge mirror,
409 retry; paint sha-negotiation upload + on-demand download (§8.3).

### WP12 — Integration: game vs live local server end-to-end; then export the
web build and deploy to the mini-pc port-91 site (game only — the Laravel app
deploys in a later round).

## Campaign 3 — one palette + crayon features (game), web authoring (server) (2026-08-07)

Backlog **BL-20…BL-24**; the design was updated first — DESIGN.md §1 (the palette) and
DLC_SERVER.md §10.3 (web authoring) are the authorities. Two independent workstreams in
disjoint directories, safe to run in parallel.

> **Status (2026-08-07): done and deployed.** WP13 (BL-20…23) and WP14 (BL-24) both
> landed, integration ran the same day: game + server deployed to the mini-pc, the
> pinned headless Godot 4.5.1 binary installed there
> (`/home/gemini/godot/`, `COLORINGBOOK_GODOT_BINARY` in the box's `server/.env`),
> mapping verified end-to-end on the box, and the queue drains via the every-minute
> scheduler (`queue:work --stop-when-empty` in `routes/console.php`). A same-day
> follow-up round covered BL-25 (release builds ship no books — the shelf is fully
> server-fed) and BL-19/BL-26 (web download fix, delta updates). Per-entry as-built
> notes live in BACKLOG.md.

### WP13 — Game: palette round (one Opus agent, entries in order)

All four entries touch the same palette files, so they are sequential inside one agent.
Order matters — BL-20 deletes the adult half first so the later features are built once,
on the surviving palette:

1. **BL-20** — single palette: delete mode select, the adult palette + swatch/slider,
   `adult_palette.tres`; vestigial `GameState.mode` / save `"mode"`; threshold 0.90.
2. **BL-21** — landscape: crayons dock beside the canvas (aspect-ratio keyed).
3. **BL-22** — intensity swap (derived light→dark ladder, resolved through `color_picked`).
4. **BL-23** — fun crayon sets (authored set resources + a set-cycling control).

Every dev smoke suite green after each entry (the mode-split assertions in palette/flow/
shell/mobile smokes must be rewritten, not deleted); project runs clean via godot-mcp;
update `.claude/skills/coloring-mechanics/SKILL.md` at the end of the round.

### WP14 — Server: web authoring (one Opus agent, BL-24)

- Books/pages authoring: models + migrations, `routes/admin.php` Inertia pages +
  `routes/api/admin.php` endpoints per DLC_SERVER.md §11's web-authoring table.
- Per-page mapping job: queued shell-out to headless Godot
  (`config('coloringbook.godot_binary')`; tests use a fake binary/pre-baked artifacts —
  the suite must stay green on a box with no Godot).
- §10.1 validation + region-overlay preview surfaced on the page editor.
- One-button publish through `PublishPackDirectory` + `PublishPackVersion` (never a
  second publish path).
- `composer test` green; Dusk coverage for the new pages follows WP8's patterns.

### Integration (main session, after both)

Merge, run the full game smoke suites + `composer test`, then export the web build and
deploy game + server to the mini-pc — the standing final step of every feature round.

## Deploy (later, not this campaign)

Mini-pc deploy conventions assume one repo per site with `deploy.sh` doing
`git reset --hard`. `server/` being a subdirectory of the game repo needs either a
sparse checkout on the box or a small deploy script tweak — decide at deploy time.
Port from the 8080s (Chromium-unsafe-port gotcha). §7.4's same-origin `/api` path on the
port-91 vhost is the target topology for the web export.
