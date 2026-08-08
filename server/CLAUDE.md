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
                         WP14 — books/pages authoring, one-button publish
                         BL-37 — sticker-set/sticker authoring, same publish
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
forever, never derived from a filename or a `res://` path (design §6.1). BL-37
adds one more of the same kind, `set_uid`, for sticker sets.

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

## BL-18 — erasure: the state that wins

Design §6.3 "Erasure", §11 (the two `DELETE` routes). Routes live beside WP2's
and WP4's in `routes/api/sync.php`; the dashboard half is in
`routes/settings.php`.

**The bug.** The §6.3 merge only ever climbs, and LWW keeps the newest picture.
So "Erase all progress" and the page's "Start over" were *absences*, and an
absence always loses: the next pull put everything back and the buttons looked
broken against a synced account.

**The fix, in one sentence.** An erasure is an **instant**, stored, and every
state is measured against it — `client_updated_at <= erased_at` reads as the
empty book. Ties go to the erase, deliberately: a wipe is the newest thing
anybody said about the shelf.

### Three scopes, one rule

| Scope | Where the clock lives | Set by |
|---|---|---|
| shelf | `shelf_erasures.erased_at` | `DELETE /sync/progress`, `settings/progress` |
| page | `book_progress.page_erased_at[i]` | `DELETE /sync/paint/{book}/{page}` |
| — | (a whole book has no clock; nothing in the game erases one across devices) | |

`shelf_erasures` is a table rather than a column on `users`/`child_profiles` for
one concrete reason: the censor is a `<=` against `client_updated_at`, so the
clock must keep its microseconds, and microsecond storage on an Eloquent model
is a `$dateFormat` on the **whole** model. A column on `users` would silently
restamp every other timestamp on the account. Keyed `(user_id, profile_key)`
with the same stored generated column `book_progress` uses.

`page_erased_at` is a nullable JSON list, index-parallel to `page_statuses`,
trailing nulls trimmed — a book nobody has reset stores `null` and sends `[]`.

### The merge, with the clocks in it

`ProgressMerge::merge($a, $b, ?$shelfErasedAt)`:

```
a, b               = each censored by shelf_erased_at first (→ empty book,
                     stamped with the erase so it cannot lose to what it replaced)
page_erased_at[i]  = max(a[i], b[i])            monotonic, like furthest_page_index
page_statuses[i]   = max over the sides whose client_updated_at > page_erased_at[i]
                     (a censored side contributes `untouched`, the identity)
```

Both censors apply to each side **independently**, which is what keeps the rule
commutative and idempotent with a clock in play. `tests/Unit/ProgressMergeTest.php`
now runs its two property grids under four shelf clocks (none, before, mid-grid,
after) and carries three erasure-bearing states in the grid itself. An erase that
were order-dependent would resurrect on one device and not another, which is
exactly the bug.

### `DELETE /sync/progress`

```
DELETE /api/v1/sync/progress   {profile?, erased_at?}
    → {erased_at, books_erased, pictures_erased, server_time}
```

`App\Actions\Sync\EraseShelf`: advance the clock (inside the transaction, first
— it is the only part that must survive), delete the shelf's
`retained_paint_layers` → `paint_layers` → `book_progress`, then sweep the blobs
**after the commit**, one `directoryFor()` per book. Not `forgetUser()`: an
account-level shelf's books sit directly under `paint/<user_ulid>/`, *beside*
the child directories, so there is no single directory meaning "the account's
pictures and not the children's".

- **Rows are deleted, not tombstoned.** The clock alone is enough, and it means
  a wiped shelf really is empty.
- `erased_at` is the **device's** clock, clamped like `client_updated_at` (an
  erase stamped a decade ahead would keep the shelf empty for a decade). Absent
  means now.
- Monotonic and therefore idempotent — the client keeps the instant in its queue
  and re-sends until a drain succeeds.
- `GET /sync/progress` publishes the clock as a top-level `erased_at`, **never
  filtered by `since`**: the rows are gone, so a cursored pull has nothing else
  to learn it from.
- `PUT /sync/progress` censors every pushed book against it, and — the case that
  matters — `ApplyBookProgress` censors the *create* path too. A device that
  slept through the wipe arrives with no row to conflict against, and "recreating
  progress beats losing it" would otherwise resurrect the whole shelf.

### `DELETE /sync/paint/{book_uid}/{page}`

```
DELETE /api/v1/sync/paint/{book_uid}/{page}   {profile?, client_erased_at?}
    → {book_uid, page_index, erased_at, revision, picture_erased}
```

`App\Actions\Sync\ErasePageProgress`. One instant, both halves of the page:

- The **picture** loses LWW to it exactly as another upload would (newer or an
  exact tie wins; older is `409 PAINT_STALE` with `details.server`, because a
  picture painted on another device *after* the reset is the newer statement).
- The **status** is censored by `page_erased_at[i]`, which is what stops a device
  still holding `complete` from putting the badge back on a blank page.

The progress row's `revision` **and** `updated_at` both move — unlike a paint
upload, which deliberately leaves them alone. An erase changes progress, so it
has to wake the `since` cursor and make every stale `base_revision` conflict.

**Nothing is retained.** §6.3's 30-day net is for a race nobody chose to lose;
this is a deliberate reset that already deletes the local file with no undo, so
the retained versions and their blobs go with it. Keeping them would leave the
dashboard offering to restore a picture onto a page a child asked to start over.

Both the negotiation and the `PUT` refuse a picture painted at or before either
clock, before a megabyte moves.

### Codes this adds

`PAINT_ERASED` (409, `details.erased_at`) — the *page* was started over more
recently than this picture; the device should delete its copy.
`PROGRESS_ERASED` (409, `details.erased_at`) — the *shelf* was erased more
recently; the device should pull progress and converge on empty. Two codes
rather than one because the remedies are different sizes, and because without
the second a stale upload would recreate the `book_progress` row it hangs off
and put a book back on a shelf the parent just cleared.

### The dashboard

`settings/progress` (`progress.edit` / `progress.destroy`,
`resources/js/pages/settings/Progress.vue`). One row per shelf — the account's
own plus one per child, empty ones included, because "there is nothing here" is
the answer a parent came to check. `{shelf}` is a child's ULID or the literal
`account`. Session auth, never a token, and a two-step confirm: it is the same
rule and the same shape as the pictures page.

### Testing erasure

`tests/Feature/Api/ProgressErasureTest.php` (14),
`tests/Feature/Api/PageErasureTest.php` (17),
`tests/Feature/Settings/ProgressPageTest.php` (8), plus the erasure block and
the clocked property grids in `tests/Unit/ProgressMergeTest.php`. Every one of
them is really the same question: after the erase, can anything put the
colouring back?

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

### Known gap for WP5 — closed

Pack covers were only reachable through the entitled delta route, so the shop
could not render a cover for a pack nobody owns yet. WP5 added
`GET /packs/{slug}/cover`; see "Covers are public, by route" below.

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

## WP5 — admin upload, validation, preview, publish

Design §10 (admin flow, and what the server validates versus what stays a dev
tool), §11 "Admin". Routes live in `routes/api/admin.php` (tokens) and
`routes/admin.php` (Inertia). It is a **single-operator tool**: no roles, no
approval chain, no workflow states beyond `draft → published → retired`.

### Two doors, one boolean

`users.is_admin` is the whole authorisation model, and
`App\Http\Middleware\EnsureAdmin` is the whole enforcement. It stands behind
two stacks:

| | `/api/v1/admin/*` | `/admin/*` (Inertia) |
|---|---|---|
| Who | the dev box's `pack build` script | a person in a browser |
| Auth | `auth:sanctum` + `abilities:admin` | `auth` (Fortify session) |
| Non-admin | `403 FORBIDDEN` | **`404`** |

The 404 is deliberate: an ordinary parent should never learn the section
exists, and `AppSidebar.vue` renders no nav entry unless `auth.user.is_admin`.

The `admin` ability is **not** in `coloringbook.token.abilities`, so no game
token can ever reach these routes, and an admin token cannot read anyone's
colouring. Mint one with:

```
php artisan admin:token you@example.com [--name=pack-build] [--days=90]
```

There is no endpoint and no button that issues it — publishing a pack should
require a shell on the server. `config('coloringbook.admin.ability')` names it.

### The surface

```
POST /admin/assets                                multipart → {asset_ulid, sha256}
GET  /admin/packs                                 every pack, drafts included
POST /admin/packs                                 create a draft pack
GET  /admin/packs/{slug}
POST /admin/packs/{slug}/versions                 zip OR manifest+ulids → draft
GET  /admin/packs/{slug}/versions/{v}/preview     the page list
GET  .../preview/{book_uid}/{page}                one region-overlay PNG
POST /admin/packs/{slug}/versions/{v}/publish     flips published_at
POST /admin/entitlements                          promo/gift grant, and un-revoke
```

§11 lists one `preview`; it is two routes here because a page list is JSON and
an overlay is a PNG, and a document carrying a pack's worth of base64 art would
be unusable. The same two exist under `/admin/...` for the browser, since an
`<img src>` cannot carry a bearer token.

`POST /admin/assets` is idempotent by construction: content addressing means
identical bytes resolve to the same row. Identity is `(sha256, kind)`, not
`sha256` — one blob legitimately wears two roles.

`POST /admin/entitlements` is a *re-*grant. `Entitlements::grant()` still never
touches an existing row (a revoked pack stays revoked however often a client
retries), so `Entitlements::regrant()` is the one way back and it lives behind
an admin typing an email into a form. `purchase` and `free` are not offerable
sources: one is written by store verification, the other writes itself on first
download.

### The draft/publish split

`PublishPackDirectory` is still the only code path that creates a
`pack_versions` row. WP5 extended it with a fourth argument rather than
bypassing it:

```php
$publisher->handle($dir, $slug, $isFree, publishNow: false);
```

`false` writes every artifact and every catalog row but leaves `published_at`
null **and leaves `packs.status` alone** — so a brand-new pack stays a draft
and a retired pack stays retired while a fix is being drafted. `pack:publish`
still passes `true` and behaves exactly as it did.

`App\Actions\Admin\PublishPackVersion` is the other half: it stamps
`published_at` and promotes a draft pack. Published rows are immutable, so
publishing an already-published version is a
`409 PACK_VERSION_ALREADY_PUBLISHED` rather than a no-op — silently agreeing
would leave every device believing it is up to date.

Upload flow, shared between the two doors:

1. `StagePackDirectory` — unpacks the zip **entry by entry** (never
   `extractTo`, which will happily write `../../.env`), checking each path
   against `PackManifest::isSafeRelativePath()` and capping the unpacked size;
   or re-materialises the tree from `manifest` + `path → asset_ulid`.
2. `SubmitPackVersion` — `PackManifestValidator` (structural) first, then
   `PackValidation` (pixels) only if the structure held, because "the regions
   JSON disagrees with the ID map" is noise when neither file is the one the
   manifest listed. Failures are a `422 PACK_VALIDATION_FAILED` whose
   `error.details` carry `{errors[], warnings[]}` — every problem at once.
3. `PublishPackDirectory`, as a draft.

### `PackValidation` — the §10.1 checks

`App\Services\PackValidation` is the pixel half that `PackManifestValidator`
deliberately isn't. Per page: display and ID map are identical dimensions; the
manifest's `image_size` matches; the regions JSON is schema v1 and its own
`image_size` matches; **the JSON ids and the ID map's non-black colours are the
same set, counted in both directions**; `#000000` is present; `region_count`
agrees with the JSON; and the largest region covers less than
`coloringbook.admin.giant_region_fraction` (0.9) of the *paintable* pixels.

The bijection is the one that earns its keep: a one-way check passes happily on
a JSON that is a subset of a newer run, and the page then has shapes nobody can
tap. A giant region is a **gap in the line art** — the artist must close it,
which is exactly why the server reports it rather than trying to fix it.

Minimum region area is not re-checked: the pipeline drops specks below
`--min-area` before it ever writes an ID map. Masks are optional and never part
of this contract (BL-9).

It runs on the admin upload path only — `pack:publish` keeps its existing
structural-only behaviour, so the CLI's contract didn't move under WP3's tests.

Reading `*_regions.json`: canonical schema v1 is the pipeline's own output
(`version`, `image_size`, `regions[{id, id_color, outline, holes, centroid,
area_px}]`). The reader also accepts `schema_version` for `version` and an `id`
that is already `#RRGGBB`, because both spellings exist in fixtures; everything
resolves to a region colour, which is all the bijection cares about.

`App\Services\RegionImage` wraps GD for both this and the preview, and exists
for two reasons that are easy to get wrong: it forces palette PNGs to
truecolour (`imagecolorat` on a palette image returns an *index*, which makes
every check downstream nonsense) and it masks the alpha byte off, because
`id = R<<16 | G<<8 | B`.

### Preview mechanics

`App\Services\PackPreview` composites each region of the ID map as a flat tint
under the display art — the same debug overlay the game has, in the browser
(§10.1). Tints are **random-but-stable** (hashed from the region's own ID-map
colour), so a page looks the same on every reload and two adjacent regions the
artist thinks are one shape show as two colours; a fixed palette would hide
exactly the failure being looked for. `#000000` is left alone, so line work
shows through as drawn.

The ID map is downscaled **nearest-neighbour** (`imagecopyresized`) and the
display art resampled (`imagecopyresampled`): a smooth resample of an ID map
averages neighbouring ids and invents colours belonging to no region. Output is
capped at `coloringbook.admin.preview_max_px` on the long edge and cached at
`packs/<slug>/v<N>/previews/<book_uid>/page_<i>.png`.

Source bytes come from the release's unpacked `files/` tree, which exists for
drafts too — so a draft is reviewable before anything is published.

### Covers are public, by route

`GET /api/v1/packs/{slug}/cover` — no auth, no signature, `listable` packs
only, `Cache-Control: public, max-age=86400` with the digest as the ETag.
`PackResource` gained a `cover_url` beside the pack-relative `cover`.

The alternative was copying covers onto the `public` disk at publish time. That
is one fewer PHP request per thumbnail, but it splits a pack's bytes across two
storage roots, needs `storage:link` in every deploy, and leaves a
published-then-retired pack's cover reachable forever with nothing in the
database saying so. A route keeps **one** content-addressed store and keeps the
decision where the rest of the catalog's status rules already live.

### Admin UI

`resources/js/pages/admin/{Packs,Pack,Preview,Entitlements}.vue`, starter-kit
components, plain string URLs rather than Wayfinder helpers. The web
controllers call the same actions and the same FormRequests as the API; where
the API answers a bad pack with a 422 and a list, the UI bounces to the pack
page with that list in the session (`pack_errors` / `pack_warnings`), because a
reviewer needs to read six problems at once.

### Testing

`Tests\Concerns\AdminsPacks` provides `adminToken()`, `packUpload()` (a real
zip of a fixture directory) and the fixture paths. `fakePackStorage()` first,
as always.

- `tests/Fixtures/packs/meadow-mates` — a second, deliberately separate pack
  from WP3's `forest-friends`. §10.1 is stricter than the structural checks
  WP3's fixture was written against (its badger page is a single region, i.e.
  100 % of the paintable pixels), so WP5 needed a pack that is *valid* end to
  end: 16×16 pages, two black bars leaving four 7×7 quadrants, regions JSON in
  the canonical schema-v1 shape.
- `tests/Fixtures/pages/<case>` — one page each, broken in exactly one way
  (`dimension-mismatch`, `json-id-missing-from-idmap`,
  `idmap-colour-missing-from-json`, `no-black`, `giant-region`,
  `image-size-mismatch`, `bad-schema`). The unit tests assert both that the
  right problem was found *and* that nothing else was.

### Platform note

If `composer test` dies inside Pint with a phar path pointing at a *different*
worktree, that is opcache's shared segment holding another checkout's
compilation of the same Pint phar, not your code. `php -d opcache.enable_cli=0
<composer> test` steps around it.

## WP14 — web authoring: books, pages, one-button publish (BL-24)

Design §10.3 (the authority), §10.1 (validation), §7.2/§7.3 (pack layout,
immutability), §11's web-authoring route table. Routes live beside WP5's in
`routes/api/admin.php` (token) and `routes/admin.php` (Inertia); it is the same
single-operator tool, extended from an *upload door* into an *authoring
surface*.

The §10.1 decision — "the mapping pipeline stays a local dev tool" — is
**amended, not reversed**. The dev-box run is still canonical for hand-tuned
pages and `pack:publish` is untouched; what changed is that a book can now be
built end to end in the browser, with the server running the same pipeline
through the escape hatch §10.1 reserved.

### The authoring data model, and why it is a second pair of tables

`books` and `pages` cannot hold draft state. They are a **projection of the
newest published release** — `PublishPackDirectory::rebuildCatalog()` drops and
recreates them on every publish, deliberately, so that progress and paint (which
key off `book_uid` and page index, never these row ids) are unaffected. A page
uploaded but not yet mapped, a title changed since the last release, a per-page
tuning override: none of it can live there without being deleted by the next
publish.

So authoring gets its own tables and the two stay visibly separate:

```
authored_books   id, ulid, book_uid (unique), pack_id →packs, title, blurb
authored_pages   id, ulid, authored_book_id, page_index, title,
                 display_asset_id  →assets      the operator's upload
                 mask_asset_id     →assets nullable   the artist's original
                 idmap_asset_id    →assets nullable   ┐
                 regions_asset_id  →assets nullable   │ derived: cleared and
                 mask_artifact_asset_id →assets nullable  recomputed on every
                 image_w, image_h, region_count       ┘ art or tuning change
                 mapping_status, mapping_error, mapping_log, mapped_at
                 validation_errors json, validation_warnings json
                 tuning json
                 UNIQUE(authored_book_id, page_index)
```

- **The workspace is draft state; the catalog is what players have.** Editing an
  authored book changes nothing anyone can see until publish.
- **One book ↔ one pack, `packs.slug = book_uid`.** Packs stay the delivery and
  entitlement unit and the game client did not move an inch; the operator thinks
  in books. The pack is created *with* the book (not lazily at publish) so the
  slug — a pack's permanent address in every URL the game builds — is reserved
  the moment the uid is.
- **`book_uid` is checked three ways** on creation: unique in `authored_books`
  (no two drafts), unique in `books` (no published release owns it — uids are
  never reused, §6.1) and unique as a `packs.slug`.
- **The two mask columns are BL-9 and BL-12 respectively.** `mask_asset_id` is
  the artist's print-size original and the *mapping source* when present;
  `mask_artifact_asset_id` is the pipeline's display-resolution resample and the
  one that ships as `page_NN_mask.png`. No mask at all is a normal page: the
  display image maps itself and no mask file appears in the pack.
- **Derived columns are nullable on purpose.** "Uploaded, not mapped yet" is the
  normal state of a page for as long as the queue takes, and a defaulted ID map
  is how a half-mapped page gets published.

`page_index` is 0-based like every other page index on this API; the *file* stem
is 1-based (`page_01` for index 0), which `AuthoredPage::fileStem()` is the only
place that knows — the same rule `PaintStorage` follows on the sync side.

### The mapping job, and the one seam

`App\Jobs\MapAuthoredPage` (queued; `tries = 1`, because a drawing with a gap in
it does not map better on the second attempt):

1. Stage a scratch directory — display at `page_01.png`, and **the mask at
   `source/mask.png`, never at `page_01_mask.png`**, which is the path the
   pipeline writes its own resample to.
2. `App\Services\Mapping\MappingRunner::run()`.
3. Store `page_01_idmap.png` / `page_01_regions.json` (+ the resampled mask) as
   content-addressed assets, via `StoreAssetFile`.
4. Run the existing `PackValidation` over the page and store the verdict.

**Nothing in the job throws on a bad page.** A failed run is a state on the row:
the queue retrying a gap in the line art would produce the same failure three
times and lose the message.

`MappingRunner` is the **only** seam between this application and the pipeline,
and it exists for exactly one reason: a shell-out is not testable on a box with
no engine. There is no PHP mapping code here and there must never be — §10.1
spends four paragraphs on why, and a second implementation that drifts by one
anti-aliasing threshold produces ID maps that hit-test differently from every
page ever shipped.

- `GodotMappingRunner` builds
  `<godot> --headless --path <project> --script tools/generate_region_map.gd --
  <source> [--display <page>] [flags]`. The positional argument is the **mapping
  source** (the mask when there is one); absolute paths pass through the
  script's `res://` normalisation untouched, which is what lets the scratch
  directory live outside the game repo. Every tunable is passed explicitly, so a
  run is reproducible from the summary the pipeline prints.
- A missing or unconfigured binary is a **failed run with a sentence**, not an
  exception. A box with no engine shows "no headless Godot is configured here"
  on the page; it does not 500 and leave a row stuck at `running`.
- `Tests\Support\FakeMappingRunner` drops pre-baked `tests/Fixtures/pages/<case>`
  artifacts into the paths a real run would have written. Bind it with
  `AuthorsBooks::fakeMapping()` **before** creating a page —
  `QUEUE_CONNECTION=sync` means the job runs inline, which is deliberate: a page
  that came back from an endpoint has really been through staging → run → store
  → validate.

Config (`config/coloringbook.php`): `godot_binary` (top level, **null by
default**), plus `authoring.godot_project` (defaults to the sibling `../godot`),
`authoring.mapping_script`, `authoring.mapping_timeout_seconds`,
`authoring.queue`, `authoring.max_image_kb`, and `authoring.tuning` — the
pipeline's own flag defaults, pinned here so a run is reproducible from the
server's config rather than from whichever version of the script is checked out.
A page may override any knob (`authored_pages.tuning`); the names are the
pipeline's own, so a page tuned in the browser can be re-run by hand on the dev
box with the same flags.

### Publish is one button and still one code path

`App\Actions\Authoring\PublishAuthoredBook` refuses while any page is unmapped
or failing §10.1 — with the *whole* list, in the operator's language — then
writes a §7.2 directory from the book's current pages and hands it to
`SubmitPackVersion` (structural + pixel validation, then `PublishPackDirectory`
as a draft) followed by `PublishPackVersion`. **There is no second publisher.**
Every `pack_versions` row in this application, from `pack:publish` to the admin
zip upload to this button, comes out of `PublishPackDirectory`.

Validating again at publish, over artifacts this server generated and already
checked, is not ceremony: assets can have been replaced, pruned or re-mapped
since, and the release is immutable the moment it exists. Cheap check before
irreversible act.

The pack cover and the book cover are both page one's display art — a one-book
pack has nothing else to be a cover, and content addressing means one blob
wearing two `assets.kind` hats costs one file. Edits after a publish accumulate
as draft state until the button is pressed again, which is v2, never a rewrite
of v1 (§7.3).

### Deleting a book: the one rule that is not obvious

- **Never published → deleted outright**, pack row, versions, catalog rows,
  entitlements and the `packs/<slug>/` directory. Nobody owns it, and leaving a
  dead slug behind would reserve a `book_uid` for a mistake forever.
- **Published → the pack is retired**, and only the authoring workspace goes.
  `Pack::scopeDownloadable()` includes `retired` precisely so delisting never
  takes a book off a child's shelf (§7.3). The uid stays claimed, which is
  correct.

Assets are never deleted either way: they are shared by digest, and a published
release may be standing on the same bytes.

### The surface

```
GET    /admin/books                              every authored book
POST   /admin/books                              create a book + its one-book pack
GET    /admin/books/{book}                       the book, with its pages
PATCH  /admin/books/{book}                       retitle (never the uid)
DELETE /admin/books/{book}                       delete, or retire once published
GET    /admin/books/{book}/pages                 the page list       (token door only)
POST   /admin/books/{book}/pages                 add a page
GET    /admin/books/{book}/pages/{index}         one page / the editor
PATCH  /admin/books/{book}/pages/{index}         title / reorder / replace art / tuning
DELETE /admin/books/{book}/pages/{index}         remove and close the gap
GET    /admin/books/{book}/pages/{index}/status  mapping state + §10.1 verdict (JSON)
GET    /admin/books/{book}/pages/{index}/preview the region-overlay PNG
POST   /admin/books/{book}/publish               build + validate + publish
```

Both doors, same actions, same FormRequests — the WP5 pattern. Art arrives
either as multipart (`display`, `mask`) or as `display_asset_ulid` /
`mask_asset_ulid` naming rows already uploaded to `POST /admin/assets`; both
converge in `App\Concerns\ResolvesAuthoringAssets`. `PATCH` carries four
unrelated edits, so every field is `sometimes` and `remove_mask` is a separate
boolean — an absent file field and a deliberately cleared one look identical in
a multipart body.

Codes this package adds: `BOOK_NOT_PUBLISHABLE` (422, `details.errors` carrying
every reason), `PAGE_NOT_MAPPED` (404, asking for the overlay of a page that has
no ID map yet).

### Things that will bite

- **Reordering renumbers the whole book.** `(authored_book_id, page_index)` is
  unique and SQLite checks unique indexes per statement, so
  `UpdateAuthoredPage::moveTo()` is a two-phase shuffle: everything is pushed
  into a range nothing occupies, then written back in the new order. A straight
  swap collides on the way past itself. Deleting a page compacts the same way —
  a hole at index 2 would publish a manifest the client reads as a book with a
  missing page.
- **Anything that changes the mapping clears the derived columns and re-queues**
  (new display, new mask, mask removed, tuning moved). Leaving yesterday's ID
  map beside today's art is the exact failure `PackValidation`'s bijection check
  exists to catch, and it would be this application that created it.
- A reorder moves a page out from under its own URL, so the web controller's
  redirect follows it to wherever it landed.
- `PackPreview::renderPair()` is the authoring-side entry point: same
  compositor, same nearest-neighbour ID-map rule, no cache of its own.
  `AuthoredPagePreview` caches on the packs disk under the two artifacts'
  digests, so a re-map is a different key and there is no invalidation step to
  forget.

### Testing

`Tests\Concerns\AuthorsBooks` — `fakeMapping()`, `pageUpload()`, `authorBook()`.
`fakePackStorage()` first, as always.

- `tests/Feature/Api/AdminBookAuthoringTest.php` — the flow through the token
  door, including "a masked page maps from the mask", "a giant region is
  reported in plain language", "publishing refuses while a page is failing" and
  "publishing again is a new immutable version".
- `tests/Feature/Admin/AuthoringPagesTest.php` — the Inertia half: the 404 for a
  parent, and a refused publish bouncing with the whole list.
- `tests/Feature/Admin/GodotMappingRunnerTest.php` — the command line, with
  `Process::fake()`.
- `tests/Feature/Admin/MappingPipelineIntegrationTest.php` — **opt-in**, skipped
  unless `COLORINGBOOK_GODOT_BINARY` names a real engine. It is also the check
  §10.3 asks for when the pinned engine moves:

  ```
  COLORINGBOOK_GODOT_BINARY="…/Godot_v4.5.1-stable_win64.exe" \
      php artisan test --filter=MappingPipelineIntegrationTest
  ```

  (The 16×16 page fixtures need `min_area` 4 and `dilate` 0 — the shipped
  defaults would drop 7×7 quadrants as specks. Per-page tuning is what the
  overrides are for.)

## BL-37 — sticker packs: a second content kind

Design §5 (the tables), §7.2 (the manifest's `kind` and the sticker layout), §10.4
(authoring), §11 (the routes). Routes live beside WP14's in `routes/api/admin.php`
and `routes/admin.php`.

**The claim the whole entry rests on: a sticker pack is the same pack.** Same zip,
same manifest, same `PublishPackDirectory`, same entitlements, same signed
downloads, same delta updates. What is new is one column, one payload array and
one validator.

### `packs.kind`, and back-compat

`book` (the default) or `sticker_set`. An **absent** `kind` in a manifest means
books — every manifest written before BL-37 has none and every one of them is
books — and the column defaults the same way, so no existing row, client or delta
moved. `PackManifest::published()` writes it out explicitly, so a *published*
manifest always says what it carries.

The kind decides exactly two things and nothing else: which payload array
`PackManifestValidator` requires, and which catalog tables `rebuildCatalog()`
rebuilds. An unknown kind is an error, not a book.

### The tables, and the same two-table split WP14 drew

```
sticker_sets      id, ulid, pack_id, set_uid (unique), title, cover_asset_id, sort_order
stickers          id, sticker_set_id, sticker_index, sticker_id, title,
                  image_asset_id, image_w, image_h
                  UNIQUE(set, index)   UNIQUE(set, sticker_id)

authored_sticker_sets  id, ulid, set_uid (unique), pack_id, title, blurb, sort_order
authored_stickers      id, ulid, authored_sticker_set_id, sticker_index, sticker_id,
                       title, image_asset_id, image_w, image_h,
                       validation_errors json, validation_warnings json
```

- `sticker_sets`/`stickers` are a **projection of the newest release**, dropped and
  rebuilt on every publish, exactly like `books`/`pages`. The `authored_*` pair is
  the workspace.
- `set_uid` is the sticker half of `book_uid` (§6.1): authored, globally unique,
  stable forever, and named by every sticker placement in a child's save (BL-36).
  Checked three ways on creation — `authored_sticker_sets`, `sticker_sets`, and
  `packs.slug`, which is one namespace shared with books.
- `sticker_id` is unique **within its set**. Two sets may both offer a `star`; a
  saved placement names the pair.
- There is no ID map, no regions JSON, no `region_count` and no `mapping_status`.

### `StickerValidation` — and the absence of a pipeline

`App\Services\StickerValidation` is `PackValidation`'s much smaller sibling and
runs **inline on upload**, not in a queued job, because a sticker has no regions
and therefore no pipeline to run. Per image: it decodes; it is between
`coloringbook.admin.sticker_min_px` (64) and `sticker_max_px` (1024) on both
sides; something is drawn (a fully transparent image is an *error*). "No
transparent pixels at all" is a **warning** — a deliberately square sticker is
legal, it will just paste a box over a child's drawing, and the operator is
looking at a preview.

`SubmitPackVersion` branches on the kind for its second layer: `PackValidation`
for a book pack, `StickerValidation` for a sticker one. The structural layer
(`PackManifestValidator`) is shared and runs first, unchanged.

### Publish is still one code path

`App\Actions\Authoring\PublishAuthoredStickerSet` refuses with the whole list, then
writes the §7.2 sticker directory and hands it to `SubmitPackVersion` →
`PublishPackDirectory` (draft) → `PublishPackVersion`. **No second publisher.**

Two details worth knowing before touching it:

- **Files are named after the stable `sticker_id`, never the index.** An index
  moves when the set is reordered, and a delta would then re-fetch every file after
  the one that moved.
- **`stickers/<set_uid>/sticker_set.json` is synthesised** into the release, added
  to the `files` map so it carries a digest — §7.2's self-describing tree, and
  exactly what the client's `StickerSetDef.discover()` reads. It never opens the
  manifest.

### Deleting a set: the WP14 rule, with more teeth

Never published → deleted outright. Published → the pack is **retired** and only
the workspace goes. For a book that keeps a shelf intact; for a sticker set it also
keeps stickers on pages that are already coloured, which would otherwise empty.

### Testing

`Tests\Concerns\AuthorsStickerSets` — `stickerUpload()`, `tinyStickerUpload()` (a
sticker under the floor, for the refusal paths) and `authorStickerSet()`. There is
**no `fakeMapping()` counterpart, and that absence is the point**: nothing in this
path shells out, so the tests are real from the upload to the zip.

- `tests/Fixtures/packs/sticker-sheet` — a third pack beside WP3's
  `forest-friends` and WP5's `meadow-mates`: 64×64 discs on transparent
  backgrounds, i.e. a shape *and* clear space around it, which is what
  `StickerValidation` actually looks at. ~8 KB.
- `tests/Feature/Api/AdminStickerSetAuthoringTest.php` — the flow through the
  token door (19).
- `tests/Feature/StickerPackDeliveryTest.php` — the *existing* machinery carrying
  it: `PublishPackDirectory` imports the fixture, the shop shows the kind, a free
  sticker pack auto-grants, the delta route serves one sticker, and a manifest with
  no `kind` still publishes as a book (12).
- `tests/Feature/Admin/StickerSetsTest.php` — the Inertia half (8).
- `tests/Unit/StickerValidationTest.php` — each case asserts the right problem was
  found *and* that nothing else was (7).

`StickerSetsTest` pulls in `PaintsPages` for `useSessionGuard()` alone: it authors
through the API and then publishes through the browser, and `auth:sanctum` rewrites
the default guard for the rest of the process.

### Admin UI

`resources/js/pages/admin/{StickerSets,StickerSet}.vue`, plus a `Sticker` entry in
`AppSidebar.vue`. There is deliberately **no per-sticker editor screen** the way a
page has one: a sticker is an id and a picture, and the set screen shows every one
of them at once, which is how a sticker sheet is actually reviewed. The grid puts a
checkerboard behind each image so a sticker with no transparency reads as the
mistake it is.

## BL-39/BL-40/BL-41 — the authoring screens restructured, plus covers and animated stickers

Design §7.2 (the two manifest additions), §10.3/§10.4 (authoring), §11's route
tables. No new work package: this is BL-24 and BL-37's surface rearranged around
what the artist actually does with it, plus one optional field on each side.

### The screens

Four pages, two shapes, and the shapes match:

| | list | editor |
|---|---|---|
| books | `admin/Books.vue` | `admin/Book.vue` |
| stickers | `admin/StickerSets.vue` | `admin/StickerSet.vue` |

A **list** is four columns — name, count, status, last published — and the whole
row is the link. Creating is a button in the top right opening a dialog, not a
form parked under the list: it happens once per book and the list is read every
day. An **editor** is picture rows: a page shows its detail image *and* its mask
(empty slot when there is none — a maskless page is normal, not broken), each
replaceable in place; a sticker shows its image, animated if it is a sheet.

`resources/js/components/ConfirmDialog.vue` is the reusable modal every delete
goes through — page, book, sticker, set. The form lives **inside** the dialog so
`processing` belongs to the button that was pressed. Nothing below these screens
has an undo.

### `last_published_at` and `modified_since_publish`

The list's third and fourth columns. `AuthoredBook::lastModifiedAt()` (and its
sticker twin) is the newest `updated_at` **anywhere in the book**, not the book
row's own: adding a page, replacing its art and reordering the lot all change
what a publish would ship and none of them writes to the book. Compared against
the newest published version's `published_at`; never published reads as
modified, because everything in the workspace is unpublished.

### Covers are optional at every layer

`authored_books.cover_asset_id`, nullable. `PublishAuthoredBook` ships it as
`books/<book_uid>/cover.png` and names it as **both** the pack `cover` and the
book `cover`; with no cover both stay page one's display art, byte for byte the
pre-BL-40 manifest. The upload rides `PATCH /admin/books/{book}` as multipart
`cover` / `cover_asset_ulid`, cleared by `remove_cover` — the `remove_mask` rule,
one level up, and for the same reason.

A missing cover **blob** at publish time is a refusal, not a quiet fallback: the
operator uploaded a cover and would otherwise get a pack wearing page one with
nothing saying why.

### Animated stickers: the contract is the absence

```json
"anim": { "hframes": 4, "vframes": 2, "frames": 7, "fps": 12 }
```

`App\Services\StickerAnim` is the single normaliser — form body, manifest entry,
validator, all through it. Three things that are easy to get wrong:

- **A still sticker has no `anim` key.** Not `null`, not `{}`. Every sticker
  published before BL-41 looks like that and so does every client reading them.
  `PublishAuthoredStickerSet` only adds the key when the row has one.
- **`frames` may be fewer than `hframes * vframes`.** Seven frames on a 4×2 sheet
  is normal. The admin preview therefore counts frames in a timer rather than
  using a two-axis CSS `steps()` pair, which always walks the whole grid and
  would show the artist a blank cell the game never plays.
- **The size bounds moved onto the frame.** `sticker_min_px`/`sticker_max_px`
  measure one cell; the file is bounded by `admin.sticker_sheet_max_px` (4096).
  The grid must divide the sheet exactly — the game slices by `hframes`/`vframes`
  without looking. Changing the grid **re-validates the same bytes**, because the
  four numbers change what the sheet means.

`anim` is submitted as `anim[hframes]` etc. — the manifest's own names. All four
or none (`required_with` across the set); an entirely blank block is a still
sticker, because `StickerAnimRules::prepareAnimInput()` strips the empty strings
an HTML form posts for fields nobody touched; an **absent** `anim` key leaves an
existing animation alone, which is what the reorder buttons post.

### Routes this adds

Both doors, mirrored as always:

```
GET /admin/books/{book}/cover                  the authored cover PNG (404: none)
GET /admin/books/{book}/pages/{i}/display      the page's own art
GET /admin/books/{book}/pages/{i}/mask         the mask (404: none)
```

`App\Concerns\ServesAuthoringImages` is the shared half; the doors differ only in
what missing looks like (a 404 page, or `COVER_NOT_FOUND` / `PAGE_ART_NOT_FOUND`
in the house error shape). These are the *files*, not the region overlay —
`preview` still answers "did the mapping work", these answer "which drawing is
this".

### Testing

`tests/Feature/Admin/BookCoverTest.php` (7),
`tests/Feature/Admin/AnimatedStickersTest.php` (11), the `anim` block in
`tests/Unit/StickerValidationTest.php` and `tests/Feature/StickerPackDeliveryTest.php`,
and the list-column tests in `AuthoringPagesTest` / `StickerSetsTest`.
`AuthorsStickerSets::spriteSheetUpload()` draws a real grid of discs.

The two tests worth keeping if everything else goes: "a book with no cover still
publishes page one as the cover", and "publishing omits `anim` for a still
sticker". Both assert that **nothing moved** for content that predates the
feature, which is the only way this stays true.

## WP8 — Dusk browser tests

`laravel/dusk` v8.6 (`php-webdriver/webdriver` 1.16) covers the human-facing
half of the app: the pages a parent or the operator actually clicks. The API is
covered by the Pest suite and is not re-tested here.

**The `composer test` gate is untouched.** `phpunit.xml` names only the `Unit`
and `Feature` suites, so `php artisan test` never sees `tests/Browser`; the
browser suite has its own `phpunit.dusk.xml`. Nothing about WP8 makes the gate
slower or browser-dependent.

### Running it

```
composer test:dusk                        # the whole browser suite
composer test:dusk -- --filter=AdminTest  # one class, or one method
```

That is a single command on purpose — a Dusk run needs a web server, a
database and a browser that all agree with each other, and getting one of the
three wrong produces a suite that goes green while proving nothing.
`tests/dusk.php` is the runner:

1. Copies `.env.dusk.local` over `.env` (original to `.env.dusk-backup`) and
   clears the config cache, so the server process, the test process and every
   artisan call below read one configuration.
2. `migrate:fresh` on the Dusk database, and empties
   `storage/app/private/dusk` — a run writes real pack, asset and paint files,
   and leftovers from a previous run are a source of tests that pass for the
   wrong reason.
3. Starts `php artisan serve --no-reload` on the port `APP_URL` names, **unless
   something is already listening there**, so you can keep a server in its own
   window if you prefer.
4. Runs `php artisan dusk`, forwarding your arguments.
5. Stops the server and restores `.env` on *every* exit path, Ctrl-C included.
   A run that leaves the development `.env` replaced by the testing one is a
   much worse failure than a red test.

To drive it by hand instead: copy `.env.dusk.local` over `.env`, run
`php artisan serve --port=8991` in one window and `php artisan dusk` in
another, then put `.env` back. `php artisan dusk` alone also works — it does
the same swap by the same filename convention, and finds `.env` already
identical so the two never fight.

### The `.env.dusk.local` contract

Committed, and containing nothing that is a secret anywhere else — the key in
it is deliberately not the development key.

| Setting | Why |
|---|---|
| `APP_URL=http://127.0.0.1:8991` | **Not** 8000. `composer dev` may be serving the real app on 8000 against the real database, and a browser test that quietly drove *that* is the worst outcome available. |
| `DB_DATABASE=database/dusk.sqlite` | A real file, never `:memory:` (two processes) and never `database/database.sqlite` — `DatabaseMigrations` runs `migrate:fresh` before **every test**, so one run pointed at the development database would wipe it. |
| `COLORINGBOOK_PRIVATE_ROOT=private/dusk` | Its own `packs`/`assets`/`paint` tree, emptied at the start of each run. |
| `MAIL_MAILER=log` | Nothing leaves the box; `log` rather than `array` so a registration test is still debuggable from `storage/logs/laravel.log`. |
| `BCRYPT_ROUNDS=4`, `CACHE_STORE=array`, `QUEUE_CONNECTION=sync` | Every test signs somebody in; a queued job must have finished by the time the redirect lands. |
| `SESSION_DRIVER=database` | Matches production — the login/logout tests are only worth anything against the session store the deployment uses. |

`config/filesystems.php` gained one thing to make that third row work: the
three private disks now read `COLORINGBOOK_PRIVATE_ROOT` (default `private`,
so nothing moved) rather than hard-coding `app/private/...`.
`config/coloringbook.php` had documented that knob since WP1 without anything
implementing it.

### `DatabaseMigrations`, and no `Storage::fake()`

`RefreshDatabase` **cannot work with Dusk**. It wraps each test in a
transaction on *this* process's connection, and the code under test runs in a
separate `php artisan serve` process that would never see inside it. Hence a
real file and `migrate:fresh` between tests (`tests/DuskTestCase.php`).

The same fact rules out `Storage::fake()` anywhere in this suite: a fake disk
exists only in the test process's container, and the process being asked for
those bytes is the server. `Tests\Concerns\SeedsBrowserFixtures` therefore
writes rows **and real files** — `seedContestedPage()` for a page that has lost
a last-write-wins race, `seedDraftPack()` importing the `meadow-mates` fixture
through the real `PublishPackDirectory` as an unpublished draft.

### What is covered

| File | Ground |
|---|---|
| `RegistrationTest` | The guardian checkbox is required; confirming it lands on the dashboard; a taken email is refused. |
| `AuthenticationTest` | Sign in, wrong password, sign out from the sidebar menu, dashboard unreachable signed out. |
| `ChildProfilesTest` | Add, rename, the **two-step** remove and its cancel, and the per-account guard rail. |
| `DevicesTest` | A seeded device renders; signing it out deletes the token row and leaves the device row and the other devices alone. |
| `AccountDeletionTest` | Wrong password deletes nothing; the right one hard-deletes the household, its paint blobs included, and nobody else's. |
| `PicturesTest` | A contested page is listed under the right shelf; restore swaps the two versions on disk and in the database; twice puts it back. |
| `AdminTest` | Non-admin: no sidebar entry and a 404. Admin: pack list, create a draft, publish a version, grant a promo entitlement, unknown email is a field error. |
| `AuthoringTest` | WP14: non-admin sees no Books entry and gets a 404; the book list, creating a book (one-book draft pack, slug = uid), the page editor rendering the region overlay, a giant region saying "a line has a gap", one-button publish, and the button disabled on a book that cannot publish. BL-39 moved creation into a dialog behind `[data-test="create-book"]` and added the delete-confirm modal, cancel included. |

`AuthoringTest` seeds pages **already mapped** (`SeedsBrowserFixtures::seedAuthoredBook()`).
The mapping job shells out inside the `php artisan serve` process, which has no
`MappingRunner` fake to bind and deliberately no engine in `.env.dusk.local`, so
the pipeline is covered by the opt-in integration test instead. `route()` hands
back absolute URLs, so the preview `<img>` is asserted with a `src$=` suffix
match, not an equality one.

Two assertions that look obvious and are wrong, both learned the hard way:

- On the pack page, `assertDontSee('draft')` and `assertDontSee('Publish')` can
  never come true — the page's own prose says "filed as a draft" and
  "Published versions are immutable". Assert that `form[action$="/publish"]`
  is gone instead.
- After a restore, `settings/pictures` does **not** go empty. A restore is a
  swap: the version it displaced takes the retained slot and is restorable in
  turn. Assert that *that* retained ulid's button is gone.

### Windows quirks

- **Chrome's "Save password?" bubble breaks the entire browser session.**
  This one cost the most to find, so: submit the login form successfully once
  and Chrome's password manager raises its save-password bubble — browser UI,
  outside the page, invisible in headless — which takes browser-level input
  focus, and **every subsequent keystroke in the session goes to it instead of
  the page**. The symptom gives nothing away: `document.hasFocus()` is true,
  the field is `document.activeElement`, WebDriver's send-keys returns success,
  and the input stays empty. Neither `type()`, `keys()`, focusing via
  JavaScript, nor a full `refresh()` recovers it. Because the fields are
  `required` and uncontrolled, the form then silently refuses to submit — no
  request, no validation message, no console output, a byte-identical DOM — and
  the test times out somewhere else entirely. `DuskTestCase::driver()` disables
  it with `--disable-save-password-bubble` plus the `credentials_enable_service`
  and `password_manager_enabled` prefs. Only the login form triggers it,
  because it is the one carrying `autocomplete="current-password"`;
  registration's `new-password` fields do not — which is exactly why the
  registration tests always passed and the ones after a login did not.
- `goog:loggingPrefs` is **not** set by Dusk's scaffolding, so
  `storeConsoleLog()` writes an empty file — indistinguishable from "no
  JavaScript errors" precisely when a test is failing because of one.
  `DuskTestCase::driver()` turns it on; `tests/Browser/console` is worth
  reading now.
- `php artisan dusk` prints `Warning: TTY mode is not supported on Windows
  platform.` on every run. It is noise.
- PAO (this box's output condenser) reads Dusk's PHPUnit-style output well
  enough for pass/fail, but `PAO_DISABLE=1 php tests/dusk.php` gives the full
  failure text with the stack frame you actually need.
- The runner kills the server with `taskkill /F /T`: `php artisan serve` runs
  the built-in server as a **child**, and terminating the artisan process alone
  orphans the thing holding the port — the next run then silently reuses a
  server pointed at the old configuration.
- The Pint/opcache note above applies to `tests/dusk.php` too: run it as
  `php -d opcache.enable_cli=0 tests/dusk.php` if Pint misbehaves.

### Helpers worth knowing before writing a browser test

`tests/DuskTestCase.php`:

- `fill($browser, $cssSelector, $value)` — types, then **reads the value back**
  before moving on. Given uncontrolled `required` inputs, an empty field fails
  silently and miles away from the cause; this makes it fail loudly and name
  the field. Takes a CSS selector, not a field name, because `value()` does not
  do `type()`'s name-attribute lookup.
- `clickUntil($browser, $selector, $until)` — a click that lands before reka-ui
  has wired a trigger is accepted by WebDriver and does nothing, and `click()`
  reports success either way. Retries up to three times, each with its own
  settle window; **never poll-and-reclick in a tight loop on a toggle**, or the
  retry closes what the first click opened.
- `visitLogin()` — waits for the passkey block, which renders late off an async
  capability probe and moves the form underneath it.
- `blank()` — clears cookies for tests that must start signed out.
- `openAccountMenu()` — the sidebar dropdown that holds "Log out".

### Chromedriver

```
php artisan dusk:chrome-driver --detect   # match the installed Chrome
```

`dusk:install` fetches the **latest** driver, which is not necessarily the one
this box needs — it pulled 151 for a Chrome 150 install. `--detect` reads the
installed browser and fetched 150.0.7871.124. Re-run it after Chrome
auto-updates; the symptom is every test failing at session creation with a
version-mismatch message.

### phpstan

Nothing to exclude. `phpstan.neon` analyses `app/`, `bootstrap/app.php`,
`config/`, `database/` and `routes/` — tests have never been in scope, so
`tests/Browser` and `tests/dusk.php` are outside it by construction. This
matches the sibling apps on this box; don't "fix" it by adding `tests/`.
