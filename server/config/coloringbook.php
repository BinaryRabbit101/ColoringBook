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
    | Admin (WP5)
    |--------------------------------------------------------------------------
    |
    | The single-operator publishing tool (DLC_SERVER.md §10). `ability` is
    | the Sanctum ability an admin *token* must carry — the dev box's
    | `pack build` script POSTs with one; the Inertia UI uses the web session
    | instead and never sees a token.
    |
    | `giant_region_fraction` is the §10.1 giant-region threshold: a page whose
    | largest region covers this share of the paintable pixels is a gap in the
    | line art, not a region. The mapping pipeline applies the same idea on the
    | dev box (`--giant-fraction`); this is the server's backstop.
    |
    */

    'admin' => [
        'ability' => env('COLORINGBOOK_ADMIN_ABILITY', 'admin'),

        // Uploads: a whole pack zip, or one page artifact at a time.
        'max_upload_kb' => (int) env('COLORINGBOOK_ADMIN_MAX_UPLOAD_KB', 262144),

        // §10.1 validation.
        'giant_region_fraction' => (float) env('COLORINGBOOK_GIANT_REGION_FRACTION', 0.9),

        // Region-overlay previews: long edge in pixels, and how strongly the
        // tint covers the display art.
        'preview_max_px' => (int) env('COLORINGBOOK_PREVIEW_MAX_PX', 768),
        'preview_tint_alpha' => (float) env('COLORINGBOOK_PREVIEW_TINT_ALPHA', 0.5),

        // BL-37 sticker images. A sticker is drawn at ~17 % of a page's short
        // side (BL-36), so the floor is "still crisp on a 2048 px page" and the
        // ceiling is "not megabytes of texture for a shape a thumb covers".
        'sticker_min_px' => (int) env('COLORINGBOOK_STICKER_MIN_PX', 64),
        'sticker_max_px' => (int) env('COLORINGBOOK_STICKER_MAX_PX', 1024),

        // BL-38 animated stickers. The two bounds above are measured on ONE
        // FRAME, not on the file: a 4x2 sheet of 256 px frames is a 1024x512
        // image that would fail a naive `sticker_max_px` check while every
        // frame in it is exactly the right size. The sheet gets its own,
        // roomier ceiling — a texture the GPU still has to hold.
        'sticker_sheet_max_px' => (int) env('COLORINGBOOK_STICKER_SHEET_MAX_PX', 4096),
    ],

    /*
    |--------------------------------------------------------------------------
    | Headless Godot — the mapping pipeline (BL-24, §10.3)
    |--------------------------------------------------------------------------
    |
    | Web-authored pages are mapped server-side by shelling out to headless
    | Godot running the game repo's own `tools/generate_region_map.gd`. There is
    | exactly one implementation of the pipeline and it is that script — never a
    | PHP port — so the server's whole job is to lay the page art out in a
    | scratch directory, run the binary, and read the artifacts back.
    |
    | `godot_binary` is null out of the box, which means "no mapping on this
    | box": a page uploaded on a machine without the engine sits at
    | `mapping_status = failed` and says so, instead of half-mapping. Point it
    | at a **pinned** build (§10.3's operational note: an engine upgrade is a
    | content-pipeline change — re-map a fixture page and diff the artifacts
    | before trusting it).
    |
    | `godot_project` is the game project the script lives in. `server/` is a
    | subdirectory of the game repo, so the default is the sibling `godot/`.
    |
    */

    'godot_binary' => env('COLORINGBOOK_GODOT_BINARY'),

    'authoring' => [
        'godot_project' => env('COLORINGBOOK_GODOT_PROJECT', base_path('../godot')),
        'mapping_script' => env('COLORINGBOOK_MAPPING_SCRIPT', 'tools/generate_region_map.gd'),

        // A 2048² page is tens of seconds of flood fill and contour tracing;
        // the ceiling is a runaway guard, not a budget.
        'mapping_timeout_seconds' => (int) env('COLORINGBOOK_MAPPING_TIMEOUT_SECONDS', 600),

        // The queue the per-page mapping job rides on. Give its worker a real
        // memory limit — §10.3.
        'queue' => env('COLORINGBOOK_MAPPING_QUEUE'),

        // One page's art. Deliberately smaller than the pack-zip ceiling: this
        // is a single PNG, not a whole release.
        'max_image_kb' => (int) env('COLORINGBOOK_AUTHORING_MAX_IMAGE_KB', 32768),

        /*
        | The pipeline's own flag defaults, pinned here so a mapping run is
        | reproducible from the server's config rather than from whichever
        | version of the script happens to be checked out. A page may override
        | any of them (`authored_pages.tuning`) — §10.3's "default tuning knobs
        | with optional per-page overrides".
        */
        'tuning' => [
            'line_alpha_min' => (float) env('COLORINGBOOK_MAPPING_LINE_ALPHA_MIN', 0.5),
            'line_luminance_max' => (float) env('COLORINGBOOK_MAPPING_LINE_LUMINANCE_MAX', 0.75),
            'dilate' => (int) env('COLORINGBOOK_MAPPING_DILATE', 1),
            'min_area' => (int) env('COLORINGBOOK_MAPPING_MIN_AREA', 64),
            'rdp' => (float) env('COLORINGBOOK_MAPPING_RDP', 1.5),
            'giant_fraction' => (float) env('COLORINGBOOK_MAPPING_GIANT_FRACTION', 0.9),
        ],
    ],

    /*
    |--------------------------------------------------------------------------
    | Paint layers
    |--------------------------------------------------------------------------
    |
    | Last-write-wins on client_painted_at, with the losing version retained
    | for 30 days at page_NN.<rev>.png so a parent can restore it (§6.3).
    | Client clocks more than `max_clock_skew_hours` in the future are
    | *rejected* — unlike progress, which clamps. A paint upload that loses to
    | a bogus future timestamp would bury a real picture behind a fake one, and
    | the client can retry a rejected upload once its clock is sane.
    |
    | `max_bytes` is the ceiling on one page's PNG. A 2048² paint layer is
    | 0.5–2 MB (§6.2); 8 MB is generous headroom and still small enough that
    | one upload can be buffered without thought.
    |
    */

    'paint' => [
        'retention_days' => (int) env('COLORINGBOOK_PAINT_RETENTION_DAYS', 30),
        'max_clock_skew_hours' => (int) env('COLORINGBOOK_PAINT_MAX_CLOCK_SKEW_HOURS', 24),
        'max_bytes' => (int) env('COLORINGBOOK_PAINT_MAX_BYTES', 8 * 1024 * 1024),
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
