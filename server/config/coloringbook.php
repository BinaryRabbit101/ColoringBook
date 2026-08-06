<?php

return [

    /*
    |--------------------------------------------------------------------------
    | X-Accel-Redirect
    |--------------------------------------------------------------------------
    |
    | When true, authorised downloads hand the bytes off to Nginx via an
    | X-Accel-Redirect header into a private `internal;` location instead of
    | streaming through a PHP-FPM worker (DLC_SERVER.md §7.4).
    |
    | Default OFF: `php artisan serve` has no Nginx in front of it, so in dev
    | we stream with Storage::download(). Flip it on in the deployed .env.
    |
    */

    'accel_redirect' => (bool) env('COLORINGBOOK_ACCEL_REDIRECT', false),

    /*
    |--------------------------------------------------------------------------
    | Internal location prefixes
    |--------------------------------------------------------------------------
    |
    | The Nginx `internal;` locations that map onto the disks below. Only used
    | when `accel_redirect` is true; each must end without a trailing slash.
    |
    */

    'accel_locations' => [
        'packs' => env('COLORINGBOOK_ACCEL_LOCATION_PACKS', '/_packs'),
        'paint' => env('COLORINGBOOK_ACCEL_LOCATION_PAINT', '/_paint'),
    ],

    /*
    |--------------------------------------------------------------------------
    | Storage
    |--------------------------------------------------------------------------
    |
    | The disk names backing the private storage layout of DLC_SERVER.md §5:
    |
    |   packs/<pack_slug>/v<version>/pack.zip
    |   packs/<pack_slug>/v<version>/files/...
    |   assets/<sha256[0:2]>/<sha256>
    |   paint/<user_ulid>/<book_uid>/page_NN.png
    |
    | The disks themselves are declared in config/filesystems.php.
    |
    */

    'storage' => [
        'packs_disk' => env('COLORINGBOOK_PACKS_DISK', 'packs'),
        'assets_disk' => env('COLORINGBOOK_ASSETS_DISK', 'assets'),
        'paint_disk' => env('COLORINGBOOK_PAINT_DISK', 'paint'),

        // Root of the private tree, relative to storage/app. The three disks
        // above are rooted at <private_root>/{packs,assets,paint}.
        'private_root' => env('COLORINGBOOK_PRIVATE_ROOT', 'private'),
    ],

    /*
    |--------------------------------------------------------------------------
    | Tokens
    |--------------------------------------------------------------------------
    |
    | Game-client Sanctum tokens expire 90 days after their last successful
    | use — the expiry slides forward on every authenticated call
    | (DLC_SERVER.md §4.2). An expired token drops the game into offline mode
    | silently; it is never a modal in a child's face.
    |
    */

    'token' => [
        'ttl_days' => (int) env('COLORINGBOOK_TOKEN_TTL_DAYS', 90),

        // Don't rewrite the expiry on every single request — only once the
        // token is this many days old. Keeps the sliding window cheap.
        'slide_after_days' => (int) env('COLORINGBOOK_TOKEN_SLIDE_AFTER_DAYS', 1),

        // Same idea for devices.last_seen_at: the dashboard wants "an hour
        // ago", not a write on every request.
        'touch_device_after_minutes' => (int) env('COLORINGBOOK_TOUCH_DEVICE_AFTER_MINUTES', 15),

        // Abilities a device token may hold. Nothing destructive: account
        // mutation always requires a fresh password confirm in the dashboard.
        'abilities' => ['save:sync', 'entitlements:read', 'packs:download'],
    ],

    /*
    |--------------------------------------------------------------------------
    | Child profiles
    |--------------------------------------------------------------------------
    |
    | The whole record of a child: a nickname and an index into the shipped
    | avatar set. No age band, no email, nothing else (DLC_SERVER.md §4.1 and
    | SERVER_BUILD_PLAN.md Q12). The nickname is never rendered outside the
    | account, so it only needs to be short enough to store and display.
    |
    */

    'profiles' => [
        'nickname_max' => (int) env('COLORINGBOOK_NICKNAME_MAX', 40),

        // avatar_index is validated as 0 .. avatar_count - 1.
        'avatar_count' => (int) env('COLORINGBOOK_AVATAR_COUNT', 12),

        // The palette/difficulty a profile opens in.
        'modes' => ['child', 'adult'],

        // A guard rail, not a product limit: keeps a scripted client from
        // filling the table.
        'max_per_account' => (int) env('COLORINGBOOK_MAX_PROFILES', 12),
    ],

    /*
    |--------------------------------------------------------------------------
    | Signed URLs
    |--------------------------------------------------------------------------
    |
    | Pack and paint downloads 302 to a short-lived temporarySignedRoute.
    |
    */

    'signed_url_ttl_minutes' => (int) env('COLORINGBOOK_SIGNED_URL_TTL_MINUTES', 10),

    /*
    |--------------------------------------------------------------------------
    | Packs
    |--------------------------------------------------------------------------
    |
    | `manifest_version` is the pack-format version this server writes;
    | `supported_manifest_versions` is every version it will still read.
    | Format changes are additive only (DLC_SERVER.md Q10).
    |
    | `min_client_version` is the floor applied to a published pack version
    | when the manifest doesn't name one — old game builds filter on it rather
    | than downloading something they cannot render (§7.3).
    |
    */

    'packs' => [
        'manifest_version' => 1,
        'supported_manifest_versions' => [1],
        'default_min_client_version' => env('COLORINGBOOK_DEFAULT_MIN_CLIENT_VERSION', '0.1.0'),
    ],

    /*
    |--------------------------------------------------------------------------
    | Paint layers
    |--------------------------------------------------------------------------
    |
    | Last-write-wins on client_painted_at, with the losing version retained
    | for 30 days at page_NN.<rev>.png so a parent can restore it (§6.3).
    | Client clocks more than `max_clock_skew_hours` in the future are clamped.
    |
    */

    'paint' => [
        'retention_days' => (int) env('COLORINGBOOK_PAINT_RETENTION_DAYS', 30),
        'max_clock_skew_hours' => (int) env('COLORINGBOOK_PAINT_MAX_CLOCK_SKEW_HOURS', 24),
    ],

    /*
    |--------------------------------------------------------------------------
    | Progress sync
    |--------------------------------------------------------------------------
    |
    | `PUT /sync/progress` is batched — one call for the whole shelf (§11) —
    | so the two limits below are guard rails on a single request, not product
    | limits: a book has a handful of pages and an account a handful of books.
    |
    | `max_clock_skew_hours` mirrors the paint knob (§6.3), but progress
    | *clamps* rather than rejects. A tablet with a wrong clock must never
    | fail to save a child's colouring; clamping to the server's now is also
    | strictly safer than rejecting, since it stops a far-future timestamp
    | winning `current_page_index` forever.
    |
    */

    'sync' => [
        'max_books_per_request' => (int) env('COLORINGBOOK_SYNC_MAX_BOOKS', 200),
        'max_pages_per_book' => (int) env('COLORINGBOOK_SYNC_MAX_PAGES', 500),
        'max_clock_skew_hours' => (int) env('COLORINGBOOK_SYNC_MAX_CLOCK_SKEW_HOURS', 24),
    ],

];
