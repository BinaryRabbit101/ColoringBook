# Agent instructions — ColoringBook server

The Laravel backend for the ColoringBook game: **device-only identities**, DLC
coloring-book packs, entitlements, and the admin publishing flow.

**Read before writing code:**

- [`../docs/DLC_SERVER.md`](../docs/DLC_SERVER.md) — the design authority.
  §5 is the data model + on-disk storage layout, §11 is the API surface.
- [`../docs/SERVER_BUILD_PLAN.md`](../docs/SERVER_BUILD_PLAN.md) — the
  implementation campaign: work packages, decisions that supersede the design
  doc, house conventions.

Where the two disagree, the build plan's "Decisions" table wins; where the
build plan is silent, the design doc rules. **Where either still describes
parent accounts, child profiles or cloud save-sync, this file wins** — see the
next section.

## The device is the identity

Internalise this before touching anything else.

There are **no player accounts**. No registration, no sign-in, no account
linking, no child profiles, no cloud save. A game install calls

```
POST /api/v1/device/register   {device_uid, device_name, platform}
    → {token, abilities, expires_at, device: {ulid}}
```

which **find-or-creates** the `devices` row for that uid and mints a Sanctum
token **on that row**. `$request->user()` is therefore an `App\Models\Device`
on every game route, and that device owns every entitlement it holds.

- **The contract above is pinned.** The Godot client codes against those exact
  field names. Do not rename, nest or drop one.
- **Abilities are exactly `entitlements:read` + `packs:download`**
  (`coloringbook.token.abilities`). `save:sync` no longer exists anywhere.
- **There is no refresh route.** A 401 is recovered by calling
  `/device/register` again with the same uid: find-or-create makes re-auth
  idempotent, the row and its entitlements survive, only the token rotates.
  The 90-day sliding window still applies (`SlideTokenExpiry`).
- **A purchase reaches a second device by re-verifying the store receipt**,
  never by signing in. See "Restore purchases" below — Google Play *requires*
  non-consumables to be restorable, so this is the load-bearing path.

`users` still exists and holds **operators only**: the person who signs in at
`/admin/*` to publish packs. `is_admin` is the whole authorisation model. Rows
come from `database/seeders` or a shell — there is no registration route in
this application at all.

## Stack

| Piece | Choice |
|---|---|
| Framework | Laravel 13, PHP 8.3+ (this box runs 8.4.0) |
| Starter kit | `laravel/vue-starter-kit` (`dev-main`) — Inertia v3 + Vue 3 + TypeScript + Vite + Tailwind 4 |
| Web auth | Fortify (session) — **login + password reset only**; no registration, no email verification, no two-factor, no passkeys |
| Client auth | Sanctum bearer tokens minted on `Device`, with abilities — **not** SPA cookie mode (design §4.2) |
| Database | SQLite, `database/database.sqlite` (house pattern: one file per site) |
| Storage | Local disks under `storage/app/private/` |
| Tests | Pest v5 |
| Static analysis | Larastan level 7 (`phpstan.neon`) |
| Formatting | Pint (`laravel` preset), Prettier + ESLint for the frontend |

## Running it

```
composer setup       # install, .env, key, migrate, npm install, npm run build
php artisan db:seed  # the first operator — admin@example.com / password
composer dev         # serve + queue + vite (php artisan dev)
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
routes/api/device.php    the only identity — POST /device/register
routes/api/catalog.php   WP3 — packs, manifest, download, entitlements
                         public free delivery, /entitlements/verify
routes/api/admin.php     WP5 — assets, pack versions, preview, publish
                         WP14 — books/pages authoring, one-button publish
                         BL-37 — sticker-set/sticker authoring, same publish
```

Each file is owned by exactly one work package so parallel agents never edit
the same route file. **Add your routes to your domain file, not to
`routes/api.php`.** Device registration stacks `throttle:6,1` on top of the
baseline.

> **Gone, and not coming back:** `routes/api/auth.php` (register, token,
> refresh, `/me`, `/profiles`) and `routes/api/sync.php` (progress, paint,
> erasure, the signed paint-blob route). Nothing in this application syncs a
> save; the game keeps its colouring in `user://` and that is the whole story.

Web/Inertia routes stay in `routes/web.php` and `routes/settings.php`.

### App layer

Domain logic lives in `app/Actions` and `app/Services`, not in controllers
(the StoryCampaign layout). Controllers validate, delegate, and shape the
response.

### Identifiers

Numeric auto-increment primary keys internally; every row that crosses the API
boundary also carries a `ulid` column and is addressed by it. `Device` and
`User` mint their ULID in a `creating` hook and set `getRouteKeyName()` to
`ulid` — follow that shape for new models.

`book_uid` is the exception: it is *authored* (e.g. `coyote-2026`), stable
forever, never derived from a filename or a `res://` path (design §6.1). BL-37
adds one more of the same kind, `set_uid`, for sticker sets.

`device_uid` is minted by the **client** and lives in `user://` forever. It is
globally unique in `devices` — nothing scopes it any more — and it is also the
*name* of that device's Sanctum token, which is the per-device revocation
story.

Resources (`App\Http\Resources\*`) are unwrapped — `JsonResource::withoutWrapping()`
is set in `AppServiceProvider`, because §11's shapes are hand-written
(`{token, abilities, expires_at, device}`, a bare entitlements array) and have
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

`App\Services\DeviceTokens` owns the 90-day sliding window.
`App\Http\Middleware\SlideTokenExpiry` is appended to the `api` middleware
group as an **after**-middleware, so any successful authenticated call slides
the expiry and refreshes `devices.last_seen_at` — you don't have to do
anything.

Every game token carries exactly `entitlements:read` + `packs:download`. Gate
your routes with `abilities:<ability>` (alias registered in
`bootstrap/app.php`).

There is a **second kind of token**, and it is not a game token: an admin
token, minted on a `User` by `php artisan admin:token`, carrying only `admin`.
It is the dev box's pack-build credential. `App\Concerns\ResolvesDevice` is how
a catalog or entitlement controller asks "is this bearer a device?"; an admin
token answers no, though in practice it never gets past
`abilities:entitlements:read` in the first place.

> **phpstan note.** Larastan types `$request->user()` from
> `auth.providers.users.model`, so an inline `$identity instanceof Device` is
> reported as always-false. `ResolvesDevice::asDevice()` and
> `DeviceTokens::deviceForIdentity()` therefore take `mixed`, which is where
> the real branch lives. Don't "fix" that back into an inline instanceof.

`Tests\TestCase` provides `registerDevice($uid)` (through the real action, so a
test that uses it also proves the abilities), `issueDeviceToken(?Device)` (a
bare token, with an optional deliberately-incomplete ability list) and
`forgetResolvedGuards()`. Use the last one between "revoke" and "try again" in
a test: the container survives between calls and Sanctum's `RequestGuard`
memoises the user it resolved, so without it a revoked token appears to keep
working.

### Storage

Two private disks, matching design §5 — see `config/filesystems.php`:

```
storage/app/private/packs/<pack_slug>/v<version>/pack.zip
storage/app/private/packs/<pack_slug>/v<version>/files/...
storage/app/private/assets/<sha256[0:2]>/<sha256>
```

Neither is web-readable. Downloads are authorised in PHP and then either
streamed (`Storage::download`) or handed to Nginx via `X-Accel-Redirect`,
switched by `config('coloringbook.accel_redirect')` — **off by default**,
because `php artisan serve` has no Nginx in front of it.

(The third disk, `paint`, went with save-sync. Nothing a child draws ever
reaches this server.)

### Configuration

App-specific knobs live in `config/coloringbook.php`: accel-redirect toggle
and internal locations, disk names, the 90-day sliding token TTL and its
ability list, signed-URL TTL, pack manifest / min-client-version defaults,
store verifiers, and the admin/authoring knobs. Read config through `config()`,
never `env()` outside a config file.

### Kids-app constraints that bind server work too

- **The PII footprint for players is zero.** A `device_uid` is a ULID the
  client minted for itself; `device_name` and `platform` are optional labels
  so a support question has something readable in it. No email, no password,
  no `age_band`, no analytics, no third-party SDKs (design §4.1/§4.3). The
  operator's email in `users` is the only address this server holds, and it
  belongs to us.
- **Nothing a child draws is uploaded**, so there is nothing here to erase,
  retain, restore or prune. "Delete my data" is a device-local act.
- Nothing the server returns should ever become a modal in a child's face: an
  expired token drops the game to offline and it re-registers silently.

## Identity, entitlements and restore purchases

Design §4.3 (the authority), §7.4 (public free delivery), §9 (receipts), §5
(ownership), §11's route tables.

**The claim the whole entry rests on: the store account is the cross-device
identity for purchases.** Play Billing and StoreKit hand the same purchase
tokens to every device signed into the same store account, so the server never
needs to *own* an identity to stop a household buying a pack twice — it needs
to verify a receipt from whichever device presents it. No email, no password,
no PII, no account.

### `POST /device/register`

`routes/api/device.php`, `throttle:6,1` stacked on the baseline.
`App\Actions\Devices\RegisterDevice` find-or-creates the row and answers
`{token, abilities, expires_at, device: {ulid}}`.

- **Find-or-create, so re-auth is idempotent.** That is what lets the refresh
  route not exist: the client re-registers on a 401 and keeps everything.
- **Re-registering rotates.** The device's old tokens are deleted before the
  new one is minted, so a uid never accumulates credentials. Its *entitlements*
  are untouched — the row survives, only its credentials turn over.
- A lost unique-index race resolves to the existing row; a genuinely
  unresolvable write is `DEVICE_REGISTRATION_FAILED` (422).
- The uid is the only secret. It is a client-minted ULID that is never
  displayed, and the route is find-or-create, so guessing one would hand over
  that device's entitlements — the same exposure a password would have had, at
  128 bits.

### Schema

```
devices       id, ulid, device_uid (UNIQUE), device_name, platform,
              last_seen_at, timestamps

entitlements  id, device_id →devices cascade, pack_id →packs cascade,
              source, platform, platform_txn_id, granted_at, revoked_at
              UNIQUE(device_id, pack_id)
              UNIQUE(device_id, platform, platform_txn_id)
```

Two decisions worth knowing before touching either table:

- **`device_uid` is globally unique.** There is nothing left to scope it to,
  and two rows for one uid would be two inventories for one install — the
  second of which would silently be the empty one.
- **Receipt uniqueness is per device, and that is the whole restore
  mechanism.** A global `UNIQUE(platform, platform_txn_id)` would let the first
  tablet claim a purchase and lock every other one out. Google Play requires a
  non-consumable to be restorable, so the same receipt is *supposed* to grant
  on N devices. Within one device it is still once-only, so a replayed receipt
  cannot mint a second row.

There are **no live users and no drop migrations**: the schema was squashed
back into the original `create_*` migrations, so `migrate:fresh` is the only
path anybody takes.

### `App\Services\Entitlements`

Every method takes a `Device`. Grant, regrant, revoke, `owns`, `live` and the
free-claim all mean exactly what they used to, per device. `device_id` is not
fillable and is stamped in `grant()` — who owns what is never something a
request body gets to say.

`App\Services\EntitlementOwner` is **gone**: there is one kind of owner now, so
the value object that told the two apart had nothing left to say.

### Restore purchases — the path that must keep working

`App\Actions\Entitlements\VerifyStoreReceipt`, behind
`POST /entitlements/verify`:

1. resolve the pack from the **SKU alone** (there is deliberately no
   `pack_slug` field, or a client could pair a valid receipt with a pack of its
   choosing). Resolution uses `downloadable()`, so a retired pack can still be
   restored (§7.3);
2. if this device already has a row, answer it — idempotent, and a re-verify on
   every launch must not cost a round trip to Google;
3. otherwise ask the platform's `StoreReceiptVerifier` and write a
   `source = 'purchase'` row for this device.

A second tablet installs the game, registers itself, asks the store what it
owns and re-verifies each token — and gets its own rows. **A test pins this**
(`ReceiptVerificationTest::test_the_same_purchase_grants_on_every_device_that_presents_it`);
if you ever tighten `platform_txn_id` uniqueness, that test is the one that
will tell you why not.

Three refusals, meaning different things: `RECEIPT_INVALID` (422 — the store
said no, do not retry), `STORE_UNAVAILABLE` (503 — we could not ask, retry),
`ENTITLEMENT_REQUIRED` (403 — this device has the pack revoked; a receipt is
not a way back, un-revoking is a deliberate admin act).

### The receipt seam, and how to fake it

`App\Contracts\StoreReceiptVerifier` is the only thing that talks to a store,
and it must stay side-effect free — the entitlement is written by
`VerifyStoreReceipt`, which is where the idempotency and
revoked-stays-revoked rules live.

```php
// config/coloringbook.php
'stores' => [
    'verifiers'   => ['google' => null, 'apple' => null, 'stripe' => null],
    'sku_columns' => ['google' => 'sku_google', 'apple' => 'sku_apple', 'stripe' => 'sku_stripe'],
    'fake'        => ['prefix' => 'test-'],
],
```

**All three verifiers ship null, and that is the safe default rather than an
oversight**: an unconfigured platform answers `STORE_UNAVAILABLE` (503,
retryable), so a deployment can never silently accept receipts it has no way of
checking. In a test, wire the fake for one platform and nothing else — and set
the others to `null` explicitly if the assertion depends on it, because a
developer's own `.env` may well name the fake:

```php
config(['coloringbook.stores.verifiers.google' => FakeStoreReceiptVerifier::class]);
```

`FakeStoreReceiptVerifier` is deterministic — valid **iff** the purchase token
starts with `stores.fake.prefix`, transaction id = the token — so "verify
twice, get one row" is a real assertion rather than a lucky one. It has two
locks against reaching production: the null default above, and `StoreReceipts`
refusing to hand it out when `app()->isProduction()`, whatever the config says.

`sku_columns` also defines the platforms the request validator accepts, so an
unknown platform is a `422 VALIDATION_FAILED` while a known-but-unconfigured
one is the 503. Two different problems, two different answers.

### Free packs are public

`manifest`, `download` and `files/{path}` sit behind `OptionalSanctumUser`
rather than `auth:sanctum`, because whether a token is required depends on the
*pack* and only the controller knows which this is.
`PackDownloadController::authorised()`:

- **free + downloadable status** → allowed, token or no token. If a token
  happens to be present the free-claim still fires, so `owned` and
  `GET /entitlements` keep meaning what they mean.
- **anything else** → 401 without a token, `403 MISSING_ABILITY` without
  `packs:download` (the same `MissingAbilityException` the middleware threw, so
  the wire response is byte-identical), then the entitlement check as before.

**The 302-to-signed-URL half did not move a byte.** The signature was always
what authorises the transfer; what changed is who may ask for one.

**The sharp edge:** a **revoked** entitlement on a **free** pack does not
refuse the download. It cannot sensibly — the same bytes are one token-less
request away. Revocation governs the *row*: the pack stays out of
`GET /entitlements`, `owned` stays false, and the claim is never resurrected
(`grant()` only fires when there is no row at all).

A token-less free fetch writes **nothing** — no entitlement, no device row.
Free play sends no identifier at all, which is the §4.3 COPPA posture.

### Codes this adds

`RECEIPT_INVALID` (422), `STORE_UNAVAILABLE` (503),
`DEVICE_REGISTRATION_FAILED` (422), `DEVICE_NOT_FOUND` (404 — the admin grant
desk, below).

### Testing

- `tests/Feature/Api/DeviceRegistrationTest.php` — the pinned contract: the
  response keys, the exact ability pair, the sliding window, rotation with
  `forgetResolvedGuards()` around the dead token, **re-registering keeps the
  entitlements**, uid uniqueness at the database level, and the rate limit
  asserted on the route rather than by hammering it (two unnamed limiters share
  a cache key, so counting responses would pin that quirk instead of the
  contract).
- `tests/Feature/Api/ReceiptVerificationTest.php` — grant, the same purchase
  granting on two devices, idempotency, revoked-stays-revoked, a rejected
  receipt, the unconfigured platform, the production refusal of the fake,
  per-platform SKU columns, a retired pack still restorable.
- `tests/Feature/Api/PublicFreePackTest.php` — every delivery route with no
  token, the paid mirror of each, "a public fetch writes no row", the free
  claim still firing behind a token, retired-stays-public / draft-is-404, and
  the manifest allow-list still governing a public delta.

## WP3 — catalog, entitlements, DLC delivery

Design §5 (catalog/entitlements), §7 (pack format & delivery), §11 "Catalog &
DLC". Routes live in `routes/api/catalog.php`. No payments: the only sources
WP3 writes are `free` and whatever WP5 grants.

### The surface

| Method | Path | Auth |
|---|---|---|
| `GET` | `/packs?client_version=` | optional |
| `GET` | `/packs/{slug}?client_version=` | optional |
| `GET` | `/packs/{slug}/manifest?version=` | **public if `is_free`**, else token + `packs:download` + entitlement |
| `GET` | `/packs/{slug}/download?version=` | **public if `is_free`**, else token + `packs:download` + entitlement |
| `GET` | `/packs/{slug}/files/{path}?version=` | **public if `is_free`**, else token + `packs:download` + entitlement |
| `GET` | `/entitlements?client_version=` | token + `entitlements:read` |
| `POST` | `/entitlements/verify` | token + `entitlements:read` |

`/entitlements` returns a **bare array** — `[{pack_slug, latest_version,
source, granted_at}]`, §11's literal shape. `/packs` returns `{packs: [...]}`
and `/packs/{slug}` returns `{pack: {...}}`.

Codes this package adds to the house error shape: `ENTITLEMENT_REQUIRED`
(403), `PACK_VERSION_NOT_FOUND` (404), `FILE_NOT_FOUND` (404),
`DOWNLOAD_LINK_EXPIRED` (403 — a stale signed URL, which the client retries by
asking for a new one rather than by hiding the pack).

### Three tiers of access

1. **Optional auth** (`OptionalSanctumUser`) on the two catalog routes and the
   three delivery routes. The shop must answer a client with no token at all,
   and add `owned` when one happens to be there; `auth:sanctum` can't express
   that. A bad token degrades to anonymous — browsing is never a failure state.
2. **Token + ability + entitlement** on anything that *names* bytes. These
   never send bytes: they `302` to a signed URL.
3. **Signed, no token** (`VerifySignedDownload`) on the routes that *move*
   bytes, so `HTTPRequest.download_file` can stream straight to
   `user://dlc/<slug>.incoming/`. TTL is `coloringbook.signed_url_ttl_minutes`
   (10).

`published` packs are listable; `published` **and `retired`** are downloadable
— delisting must never take away books a device owns (§7.3). `draft` is
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
  *(It stays revoked as a **row**; it no longer blocks the download of a free
  pack, whose bytes are public — see "Free packs are public" above.)*
- Grants are idempotent on `(owner, pack_id)` and survive the unique-index
  race two tablets can cause.
- `device_id`/`pack_id` are not fillable: who owns what is never something a
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
  A saved sticker placement keys off `book_uid`/`set_uid`, never these row ids.
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

The 404 is deliberate, and it stays even though `users` now holds operators
only: `AppSidebar.vue` renders no nav entry unless `auth.user.is_admin`, and a
non-admin row should never learn the section exists.

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
POST /admin/entitlements                          promo/gift grant by device_uid,
                                                  and un-revoke
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
an operator typing into a form. `purchase` and `free` are not offerable
sources: one is written by store verification, the other writes itself on first
download.

It addresses the claim by **`device_uid`**, not by email: the device is the
identity, and the uid is the only thing a player can read off their own screen
and paste into a support message. An unknown uid is `DEVICE_NOT_FOUND` (404 on
the token door, a field error on the form) — deliberately not an
`exists:devices` rule, because "no such device" should not look like a typo in
the form.

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
recreates them on every publish, deliberately, so that anything keyed on
`book_uid` and page index (never these row ids) is unaffected. A page
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
place that knows.

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
  non-admin, and a refused publish bouncing with the whole list.
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

`StickerSetsTest` calls `useSessionGuard()` (on `Tests\TestCase`) between its API
calls and its browser calls: it authors through the API and then publishes through
the web door, and `auth:sanctum` rewrites the default guard for the rest of the
process.

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
half of the app: the pages the operator actually clicks. The API is covered by
the Pest suite and is not re-tested here.

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
   `storage/app/private/dusk` — a run writes real pack and asset files,
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
| `COLORINGBOOK_PRIVATE_ROOT=private/dusk` | Its own `packs`/`assets` tree, emptied at the start of each run. |
| `MAIL_MAILER=log` | Nothing leaves the box; `log` rather than `array` so a password-reset mail is still debuggable from `storage/logs/laravel.log`. |
| `BCRYPT_ROUNDS=4`, `CACHE_STORE=array`, `QUEUE_CONNECTION=sync` | Every test signs somebody in; a queued job must have finished by the time the redirect lands. |
| `SESSION_DRIVER=database` | Matches production — the login/logout tests are only worth anything against the session store the deployment uses. |

`config/filesystems.php` gained one thing to make that third row work: the
private disks read `COLORINGBOOK_PRIVATE_ROOT` (default `private`, so nothing
moved) rather than hard-coding `app/private/...`.
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
writes rows **and real files** — `seedDraftPack()` imports the `meadow-mates`
fixture through the real `PublishPackDirectory` as an unpublished draft, and
`seedAuthoredBook()` seeds an already-mapped authored page.

### What is covered

| File | Ground |
|---|---|
| `AuthenticationTest` | Sign in, wrong password, sign out from the sidebar menu, dashboard unreachable signed out. |
| `AdminTest` | Non-admin: no sidebar entry and a 404. Admin: pack list, create a draft, publish a version, grant a promo entitlement **by `device_uid`**, unknown device is a field error. |
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
