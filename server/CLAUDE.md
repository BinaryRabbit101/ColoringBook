# Agent instructions — ColoringBook server

The Laravel backend for the ColoringBook game: parent accounts, cloud-synced
progress, DLC coloring-book packs, and the admin publishing flow.

**Read before writing code:**

- [`../docs/DLC_SERVER.md`](../docs/DLC_SERVER.md) — the design authority.
  §5 is the data model + on-disk storage layout, §11 is the API surface.
- [`../docs/SERVER_BUILD_PLAN.md`](../docs/SERVER_BUILD_PLAN.md) — the
  implementation campaign: work packages, decisions that supersede the design
  doc, house conventions.

Where the two disagree, the build plan's "Decisions" table wins; where the
build plan is silent, the design doc rules.

## Stack

| Piece | Choice |
|---|---|
| Framework | Laravel 13, PHP 8.3+ (this box runs 8.4.0) |
| Starter kit | `laravel/vue-starter-kit` (`dev-main`) — Inertia v3 + Vue 3 + TypeScript + Vite + Tailwind 4 |
| Web auth | Fortify (session), incl. two-factor and passkeys from the kit |
| Client auth | Sanctum bearer tokens with abilities — **not** SPA cookie mode (design §4.2) |
| Database | SQLite, `database/database.sqlite` (house pattern: one file per site) |
| Storage | Local disks under `storage/app/private/` |
| Tests | Pest v5 |
| Static analysis | Larastan level 7 (`phpstan.neon`) |
| Formatting | Pint (`laravel` preset), Prettier + ESLint for the frontend |

## Running it

```
composer setup     # install, .env, key, migrate, npm install, npm run build
composer dev       # serve + queue + vite (php artisan dev)
```

The app listens on `http://localhost:8000`. `MAIL_MAILER=log` — password-reset
mails land in `storage/logs/laravel.log`, not an inbox (build plan, Q11).

## Testing

```
composer test        # config:clear + pint --test + phpstan + pest  ← the gate
composer lint        # pint, writing fixes
composer types:check # phpstan only
composer ci:check    # the above plus eslint / prettier / vue-tsc
```

**`composer test` must be green before any work package reports done.**

## Platform quirk (same as the other sites on this box)

`composer require` / `composer update` need `--ignore-platform-req=php`: the
box has PHP 8.4.0 and parts of the Laravel 13 / Pest 5 tree want ≥ 8.4.1.
`platform-check` is already set to `false` in `composer.json` so plain
`php artisan` calls are unaffected — don't remove it.

Pint enforces LF line endings. Anything that rewrites a PHP file on Windows
(`php artisan install:*`, some generators) can leave CRLF behind; run
`composer lint` after.

## Conventions

### Routes — one file per domain

`routes/api.php` contains **no routes**. It wires the per-domain files under
the `/api/v1` prefix with the `api.v1.` name prefix and a baseline
`throttle:60,1`:

```
routes/api/auth.php      WP1 — register, token, refresh, /me, profiles
routes/api/sync.php      WP2 (progress) + WP4 (paint)
routes/api/catalog.php   WP3 — packs, manifest, download, entitlements
routes/api/admin.php     WP5 — assets, pack versions, preview, publish
```

Each file is owned by exactly one work package so parallel agents never edit
the same route file. **Add your routes to your domain file, not to
`routes/api.php`.** Auth routes stack `throttle:6,1` on top of the baseline.

Web/Inertia routes stay in `routes/web.php` and `routes/settings.php`.

### App layer

Domain logic lives in `app/Actions` and `app/Services`, not in controllers
(the StoryCampaign layout). Controllers validate, delegate, and shape the
response.

### Identifiers

Numeric auto-increment primary keys internally; every row that crosses the API
boundary also carries a `ulid` column and is addressed by it. `User` mints its
ULID in a `creating` hook and sets `getRouteKeyName()` to `ulid` — follow that
shape for new models.

`book_uid` is the exception: it is *authored* (e.g. `coyote-2026`), stable
forever, never derived from a filename or a `res://` path (design §6.1).

Resources (`App\Http\Resources\*`) are unwrapped — `JsonResource::withoutWrapping()`
is set in `AppServiceProvider`, because §11's shapes are hand-written
(`{token, abilities, expires_at, user}`, `{user, profiles, devices}`) and have
no `data` envelope.

### API error shape

Everywhere, without exception:

```json
{"error": {"code": "ENTITLEMENT_REQUIRED", "message": "…"}}
```

The game client branches on the stable snake-case `code`, never on the prose.

**This is already done for you.** `App\Exceptions\ApiExceptionRenderer`, wired
into `bootstrap/app.php`, turns *every* failure under `/api/*` into that shape:
`VALIDATION_FAILED` (plus a `details` map of field → messages),
`UNAUTHENTICATED`, `MISSING_ABILITY`, `FORBIDDEN`, `NOT_FOUND`,
`METHOD_NOT_ALLOWED`, `THROTTLED`, `SERVER_ERROR`. Never hand-roll an error
body in a controller.

For a failure the client must branch on specifically, throw
`App\Exceptions\ApiException` with your own code:

```php
throw new ApiException('ENTITLEMENT_REQUIRED', 'You do not own that pack.', 403);
```

Web/Inertia responses are untouched — the renderer only fires for `/api/*`.

### Device tokens

`App\Services\DeviceTokens` owns the 90-day sliding window; the token is
*named* after the client's `device_uid`, which is the only link between
Sanctum's table and `devices`, and therefore the whole per-device revocation
story. `App\Http\Middleware\SlideTokenExpiry` is appended to the `api`
middleware group as an **after**-middleware, so any successful authenticated
call in any work package slides the expiry and refreshes `devices.last_seen_at`
— you don't have to do anything.

Every game token carries exactly `save:sync`, `entitlements:read`,
`packs:download`. Gate your routes with `abilities:<ability>` (alias registered
in `bootstrap/app.php`). Nothing a token can reach may delete the account,
change the password or revoke another device — those live in the dashboard
behind a password re-confirmation.

`Tests\TestCase` provides `issueDeviceToken($user, $deviceUid, $abilities)` and
`forgetResolvedGuards()`. Use the latter between "revoke" and "try again" in a
test: the container survives between calls and Sanctum's `RequestGuard`
memoises the user it resolved, so without it a revoked token appears to keep
working.

### Storage

Three private disks, matching design §5 — see `config/filesystems.php`:

```
storage/app/private/packs/<pack_slug>/v<version>/pack.zip
storage/app/private/packs/<pack_slug>/v<version>/files/...
storage/app/private/assets/<sha256[0:2]>/<sha256>
storage/app/private/paint/<user_ulid>/<book_uid>/page_NN.png
```

None of them is web-readable. Downloads are authorised in PHP and then either
streamed (`Storage::download`) or handed to Nginx via `X-Accel-Redirect`,
switched by `config('coloringbook.accel_redirect')` — **off by default**,
because `php artisan serve` has no Nginx in front of it.

### Configuration

App-specific knobs live in `config/coloringbook.php`: accel-redirect toggle
and internal locations, disk names, the 90-day sliding token TTL, signed-URL
TTL, pack manifest/min-client-version defaults, paint retention and clock
skew. Read config through `config()`, never `env()` outside a config file.

### Kids-app constraints that bind server work too

- The parent's email and password are the entire PII footprint. No `age_band`,
  no child email, no analytics, no third-party SDKs (design §4.1, build plan).
- Account deletion is a real hard delete that cascades progress, paint and
  profiles — never a soft delete.
- Nothing the server returns should ever become a modal in a child's face:
  sync conflicts merge silently and surface, if at all, in the parent
  dashboard.

## Progress sync (WP2)

`routes/api/sync.php`, both gated on `auth:sanctum` + `abilities:save:sync`.

```
GET /api/v1/sync/progress?profile=<ulid>&since=<cursor>
    → {books: [{book_uid, revision, current_page_index, page_statuses,
                furthest_page_index, client_updated_at}], server_time}

PUT /api/v1/sync/progress
    {profile?, books: [{book_uid, base_revision, current_page_index,
                        page_statuses, furthest_page_index, client_updated_at}]}
    → {results: [...], server_time}
```

`profile` names a child's shelf; omitting it means the **account-level** shelf
(`child_profile_id IS NULL`), which is a separate row from any child's. A ULID
that isn't one of this user's children is a `404`, never a `403`.

### Conflicts are per book, inside a 200

The design asks for "a per-book 409", but the call is batched, and a shelf
where one book conflicted and four synced cleanly has no single HTTP status.
So the status is always `200` and every result carries its own verdict:

```json
{"book_uid": "coyote-2026", "revision": 4, "conflict": false}
{"book_uid": "fox-2026", "revision": 9, "conflict": true, "server": { … }}
```

A conflicted book was **not written**. Its `server` block is the full server
state, which is everything the device needs to merge locally and retry that one
book at `base_revision: 9`. There is deliberately no whole-request 409, not
even when every book conflicts.

Other behaviours worth knowing:

- A `book_uid` with no row yet is created at **revision 1**, and its
  `base_revision` is ignored — recreating progress beats losing it.
- A push that merges to exactly what is stored is a **no-op**: the revision
  stands and `updated_at` is untouched, so re-syncing doesn't wake every other
  device through the `since` cursor.
- `client_updated_at` is **clamped** to the server's now when it is more than
  `config('coloringbook.sync.max_clock_skew_hours')` ahead. Paint rejects a bad
  clock; progress clamps, because a save must never fail over a wrong clock.

### The merge rule

`App\Services\ProgressMerge` is pure — no clock, no database — and implements
§6.3 over `ProgressState` values: per-page `max(status)` under
`untouched < in_progress < complete`, `max(furthest_page_index)`, and
`current_page_index` from whichever side has the newer `client_updated_at`.
Unequal page counts pad with `untouched`; equal timestamps tie-break on
`max(current_page_index)` so the rule stays commutative. It is **commutative
and idempotent**, and `tests/Unit/ProgressMergeTest.php` proves both across a
grid of states rather than by example. Don't "improve" it without re-running
those properties.

### `book_progress`

One row per `(user, child_profile|null, book)`. Two things to know before
touching the table:

- The unique key is `(user_id, profile_key, book_uid)`, where `profile_key` is
  a **stored generated column** `coalesce(child_profile_id, 0)`. A plain
  `UNIQUE(user_id, child_profile_id, book_uid)` would not constrain the
  account-level shelf at all, because SQL treats two NULLs as distinct.
- Timestamps are **microsecond precision** (`timestamps(6)` plus
  `BookProgress::DATE_FORMAT` on the model). `updated_at` is the `since`
  cursor, and at whole-second resolution a row written later in the same second
  as the cursor would never be pulled. A `where('updated_at', …)` binding has
  to be formatted with `BookProgress::DATE_FORMAT` by hand — the query
  grammar's default would truncate it.

## WP3 — catalog, entitlements, DLC delivery

Design §5 (catalog/entitlements), §7 (pack format & delivery), §11 "Catalog &
DLC". Routes live in `routes/api/catalog.php`. No payments: the only sources
WP3 writes are `free` and whatever WP5 grants.

### The surface

| Method | Path | Auth |
|---|---|---|
| `GET` | `/packs?client_version=` | optional |
| `GET` | `/packs/{slug}?client_version=` | optional |
| `GET` | `/packs/{slug}/manifest?version=` | token + `packs:download` + entitlement |
| `GET` | `/packs/{slug}/download?version=` | token + `packs:download` + entitlement |
| `GET` | `/packs/{slug}/files/{path}?version=` | token + `packs:download` + entitlement |
| `GET` | `/entitlements?client_version=` | token + `entitlements:read` |

`/entitlements` returns a **bare array** — `[{pack_slug, latest_version,
source, granted_at}]`, §11's literal shape. `/packs` returns `{packs: [...]}`
and `/packs/{slug}` returns `{pack: {...}}`.

Codes this package adds to the house error shape: `ENTITLEMENT_REQUIRED`
(403), `PACK_VERSION_NOT_FOUND` (404), `FILE_NOT_FOUND` (404),
`DOWNLOAD_LINK_EXPIRED` (403 — a stale signed URL, which the client retries by
asking for a new one rather than by hiding the pack).

### Three tiers of access

1. **Optional auth** (`OptionalSanctumUser`) on the two catalog routes. The
   shop must answer a signed-out client, and add `owned` when a token happens
   to be there; `auth:sanctum` can't express that. A bad token degrades to
   anonymous — browsing is never a failure state.
2. **Token + ability + entitlement** on anything that *names* bytes. These
   never send bytes: they `302` to a signed URL.
3. **Signed, no token** (`VerifySignedDownload`) on the routes that *move*
   bytes, so `HTTPRequest.download_file` can stream straight to
   `user://dlc/<slug>.incoming/`. TTL is `coloringbook.signed_url_ttl_minutes`
   (10).

`published` packs are listable; `published` **and `retired`** are downloadable
— delisting must never take away books a household owns (§7.3). `draft` is
invisible to both.

### Free-claim semantics

`packs.is_free` is not ownership. Entitlement **rows drive everything**, so a
free pack **auto-grants itself a `source = 'free'` row** the first time an
authenticated device hits `manifest`, `download` or `files` for it. Therefore:

- `owned` in the catalog and membership of `GET /entitlements` both mean *a
  live row*, so a free pack reads `{is_free: true, owned: false}` until first
  fetch. The client offers a download for `is_free || owned`, and a purchase
  only for `!is_free && !owned`.
- **A revoked entitlement stays revoked, free packs included** — the grant only
  fires when there is no row at all. Un-revoking is a deliberate admin act.
- Grants are idempotent on `(user_id, pack_id)` and survive the unique-index
  race two tablets can cause.
- `user_id`/`pack_id` are not fillable: who owns what is never something a
  request body gets to say.

### `pack:publish`

```
php artisan pack:publish {dir} [--pack=slug] [--free|--paid]
```

`{dir}` is a built pack directory — a §7.2 `manifest.json` plus the files its
`files` map lists. It validates structurally (manifest parses and is a
supported `manifest_version`, every listed path exists with matching bytes and
sha256, every `book_uid` present, slug-shaped, unique in the pack and not
already owned by another pack, every page's display/idmap/regions listed,
`image_size` and `region_count` sane) and reports **every** problem at once via
`PackPublishException::$errors`.

Then it imports: content-addressed copies to `assets/<sha[0:2]>/<sha>`, catalog
rows, `packs/<slug>/v<N>/pack.zip` plus the unpacked `files/` tree for deltas,
and a `pack_versions` row with the manifest and the archive digest, published.

Three things worth knowing before building on it:

- **The server assigns the version.** `pack_version` in the manifest is
  advisory; publishing again is always `max + 1`, and published rows are never
  rewritten. A disagreement is a warning, not an error.
- **Books and pages are rebuilt** from the newest release rather than merged.
  Progress and paint key off `book_uid` and page index, never these row ids.
- **`books/<book_uid>/book.json` is synthesised** when the builder didn't ship
  one, and added to the manifest's `files` map so it carries a digest like
  everything else (§7.2's self-describing install tree).

The real work is `App\Actions\Packs\PublishPackDirectory`, which is the only
code path that creates a `pack_versions` row — WP5's admin upload should call
it rather than reimplement it.

### Delta downloads and path safety

`/packs/{slug}/files/{path}` serves a path **only if it is a key in that
version's manifest `files` map**. That allow-list is the load-bearing defence;
`PackManifest::isSafeRelativePath()` (traversal, absolute paths, drive letters,
backslashes, control characters) is the second layer and the single definition
shared by the publisher and the router.

### Testing packs

`Tests\Concerns\PublishesPacks` publishes `tests/Fixtures/packs/forest-friends`
through the real action, so a test downloads the bytes a player would get.
The fixture is ~7 KB: two books, three pages, 8×8 lossless PNGs with `#000000`
lines and flat per-region ID-map colours, and a pack cover that doubles as a
book cover (one blob, two `assets.kind` rows). `fakePackStorage()` first —
content-addressed writes are the first thing publishing does.

### Known gap for WP5

Pack covers are only reachable through the entitled delta route, so the shop
cannot render a cover for a pack nobody owns yet. §11 defines no public cover
route; add one (or serve covers from the `public` disk) when the shop UI lands.

## WP4 — paint-layer sync

Design §6.2–6.3 (policy, LWW, retention), §5 (`paint_layers`, storage layout),
§11 "Sync". Routes live in the paint block of `routes/api/sync.php`, beside
WP2's progress routes and behind the same `auth:sanctum` + `abilities:save:sync`
gate.

Paint is the *lazy* half of sync: 0.5–2 MB a page against progress's 200 bytes.
Everything below exists to move as few of those bytes as possible.

### The surface

| Method | Path | Answers |
|---|---|---|
| `POST` | `/sync/paint/{book_uid}/{page}` | `204` have-it / `202` + upload instructions |
| `PUT` | `/sync/paint/{book_uid}/{page}?sha256=&client_painted_at=` | `201 {revision}` / `204` / `409` |
| `GET` | `/sync/paint/{book_uid}/{page}` | `302` signed URL, or `404` |
| `GET` | `/sync/paint/{book_uid}` | per-page metadata for one book (**added**) |
| `GET` | `/sync/paint-blob/{layer}` | the bytes — **signed, no token** |

`?profile=<ulid>` scopes every one of them exactly as it does in WP2: omitted
means the account-level shelf, and a ULID that isn't one of this user's
children is a `404`.

The last row is the only route in `sync.php` outside the token group, for the
reason WP3 documents: the signature *is* the authorisation, so
`HTTPRequest.download_file` can stream straight to `user://paint/` without
carrying headers. It reuses `VerifySignedDownload` and
`PrivateDownloads::serve()` unchanged, `X-Accel-Redirect` switch included.

`GET /sync/progress` is untouched — WP2's response shape is exactly what it
was. The per-book paint metadata is a separate endpoint precisely so it stayed
that way.

### `{page}` is the page *index*; `page_NN.png` is 1-based

The API speaks 0-based indices everywhere (`page_statuses`,
`current_page_index`, and `{page}` here). The **file** is
`page_01.png` for index 0, because that is what the client already writes to
`user://paint/<slug>/` (`game_state.gd`). `App\Services\PaintStorage` is the
only code that names files, and the only place that conversion happens.

### Storage layout, and the one deviation from §5

```
paint/<user_ulid>/<book_uid>/page_NN.png                 account shelf (§5, verbatim)
paint/<user_ulid>/<profile_ulid>/<book_uid>/page_NN.png  a child's shelf
paint/<user_ulid>/…/page_NN.<revision>.png               a retained loser
```

§5's layout predates child profiles: two children painting the same book on one
account would write to the same file. The extra segment is unambiguous because
a `book_uid` is an authored lower-case slug (§6.1) and a ULID is upper-case
Crockford base32, so neither can be read as the other.

### Last-write-wins, and what each verdict means

`App\Actions\Sync\StorePaintLayer` decides, on `client_painted_at`:

- **Same sha256** → `204`, and *nothing is written* — no revision, no retained
  version, and `client_painted_at` is **not** advanced. The row describes a
  picture and that picture has not changed. Re-syncing an unchanged page is
  free, which is the entire point of the sha-first negotiation.
- **Newer, or an exact tie** → the incoming write wins (`201 {revision}`).
  §6.3 makes the server clock the tie-break, and by the server's clock the
  write arriving now is the later one.
- **Older** → `409 PAINT_STALE`, carrying `details.server` (the current
  `{page_index, sha256, bytes, revision, client_painted_at}`). Nothing is
  written. Rejecting rather than silently dropping is what tells the device
  *its* copy is the stale one, so it pulls instead of retrying forever.
- **No row yet** → revision 1, creating the `book_progress` row if the shelf
  has never synced this book — empty `page_statuses`, revision 1. Paint
  legitimately arrives before progress does; the two requests race.

A winning write does **not** touch `book_progress.updated_at`. That column is
WP2's `since` cursor, and a picture upload is no news to the other devices.

**The negotiation writes nothing at all** — not a row, not a timestamp, not
even on `204`. The `PUT` is the only thing that creates state.

### Clock skew: paint rejects where progress clamps

`config('coloringbook.paint.max_clock_skew_hours')` (24). More than that in the
future and both the `POST` and the `PUT` answer `PAINT_CLOCK_SKEW` (422) with
the server's time. Deliberately unlike progress, which clamps: a save must
never fail over a wrong clock, but a picture stamped three years out would win
LWW forever and bury every later drawing behind it. Rejection is recoverable.

### Codes this package adds

`PAINT_STALE` (409), `PAINT_CLOCK_SKEW` (422), `PAINT_NOT_FOUND` (404),
`PAINT_TOO_LARGE` (413, `coloringbook.paint.max_bytes`, 8 MB),
`PAINT_NOT_PNG` (422), `PAINT_EMPTY` (422), `DIGEST_MISSING` (400),
`DIGEST_MISMATCH` (422), `PAGE_OUT_OF_RANGE` (422).

The digest is checked **twice** (`App\Services\PaintUploads`): `Content-Digest`
against the body proves the bytes survived the wire, and the body against the
negotiated `?sha256=` proves they are the bytes both ends agreed to move. RFC
9530 (`sha-256=:<base64>:`) and the older `Digest: SHA-256=<base64>` are both
read. The client never has to build that header itself — the `202` hands back
the exact URL and headers to use.

### Retention, restore, prune

The losing version is not deleted: it moves to `page_NN.<revision>.png` and
gets a row in **`retained_paint_layers`**, a sidecar table rather than more
rows in `paint_layers` — `UNIQUE(book_progress_id, page_index)` is what makes
"the current picture" unambiguous, and relaxing it would put every reader in
the business of asking which row is live.

- **Restore** (`App\Actions\Sync\RestorePaintLayer`) is a *swap*, not a
  rollback: the demoted version takes the retained one's place with a fresh
  30-day lease, so the button can never be the thing that loses a picture, and
  pressing it twice returns the page to where it started. The restored layer is
  stamped with the **server's clock**, not the older picture's — otherwise the
  device that won the first race would win it again on its next upload and the
  button would be a lie. The original painting time travels with the version
  into retention, which is what the dashboard displays.
- **Dashboard**: `settings/pictures` (`pictures.edit` / `pictures.restore`,
  `resources/js/pages/settings/Pictures.vue`), listing only pages that actually
  have an older version. Session auth, never a token: a five year old must
  never be shown the choice (§6.3), and a game token must never be able to
  make it.
- **Prune**: `php artisan paint:prune [--days=] [--pretend]`, scheduled daily
  at 03:20 in `routes/console.php`. Blob first, row second — a row without its
  file is a broken button; a file without its row is invisible and gets swept
  by the next account deletion.

### Deletion sweeps

`DeleteAccount` and `DeleteChildProfile` now delete the paint rows explicitly
(so it is correct with foreign keys off) and then, **after the transaction
commits**, the blobs: `paint/<user_ulid>/` for an account,
`paint/<user_ulid>/<profile_ulid>/` for one child. A disk cannot be rolled
back, so the order matters.

### Testing paint

`Tests\Concerns\PaintsPages` drives the endpoints the way the game does:
`upload()` negotiates and then PUTs to whatever URL the `202` handed back, so
every test that stores a picture also proves those instructions are usable.
`png()` is a real 1×1 PNG with a suffix, so two calls differ in sha256 while
both still carry the signature the upload path checks. `fakePaintStorage()`
first.

One trap worth knowing: `auth:sanctum` calls `shouldUse('sanctum')`, which
rewrites `auth.defaults.guard` **for the rest of the process**. In a test the
container survives between calls, so after any API request a bare `auth`
(session) route will happily accept a bearer token and a "a game token cannot
do this" test silently passes for the wrong reason. `useSessionGuard()` in that
trait puts it back; call it between an API call and a dashboard call.
