<?php

use App\Http\Controllers\Api\V1\Admin\AssetController;
use App\Http\Controllers\Api\V1\Admin\EntitlementController;
use App\Http\Controllers\Api\V1\Admin\PackController;
use App\Http\Middleware\EnsureAdmin;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| Admin — WP5
|--------------------------------------------------------------------------
|
| Loaded by routes/api.php inside the `/api/v1` + `api.v1.` name group.
| Owned by WP5; no other work package edits this file.
|
| The surface (DLC_SERVER.md §11 "Admin"):
|
|   GET  /admin/packs                               list, drafts included
|   POST /admin/assets                              multipart, content-addressed
|   POST /admin/packs                               create a draft pack
|   GET  /admin/packs/{slug}                        detail + every version
|   POST /admin/packs/{slug}/versions               zip or manifest+ulids → validation
|   GET  /admin/packs/{slug}/versions/{v}/preview   the page list, with URLs
|   GET  .../preview/{book}/{page}                  one region-overlay PNG
|   POST /admin/packs/{slug}/versions/{v}/publish   flips published_at
|   POST /admin/entitlements                        promo grant / un-revoke by email
|
| ## Auth: two doors, one boolean
|
| This is the **token** door — a Sanctum token carrying the `admin` ability,
| which the dev box's `pack build` script POSTs with. It is minted by hand
| (`php artisan admin:token you@example.com`) and never by the game: a device
| token holds exactly `save:sync`, `entitlements:read`, `packs:download` and
| can no more publish a pack than delete an account.
|
| The **session** door is `routes/admin.php`, the Inertia UI, where a signed-in
| parent with `is_admin` gets the same actions through forms. `EnsureAdmin` is
| the single `users.is_admin` check behind both; it 403s here and 404s there,
| because an ordinary parent should never learn the admin section exists.
|
| Deliberately absent: any notion of roles or an approval chain. §10.2 says
| single operator, and one boolean column is the whole model.
|
*/

Route::middleware(['auth:sanctum', 'abilities:'.config('coloringbook.admin.ability'), EnsureAdmin::class])
    ->prefix('admin')
    ->name('admin.')
    ->group(function (): void {
        Route::post('assets', AssetController::class)->name('assets.store');

        Route::get('packs', [PackController::class, 'index'])->name('packs.index');
        Route::post('packs', [PackController::class, 'store'])->name('packs.store');
        Route::get('packs/{slug}', [PackController::class, 'show'])->name('packs.show');

        Route::post('packs/{slug}/versions', [PackController::class, 'storeVersion'])
            ->name('packs.versions.store');

        Route::get('packs/{slug}/versions/{version}/preview', [PackController::class, 'preview'])
            ->whereNumber('version')
            ->name('packs.versions.preview');

        // `{book}` is a book_uid, which is slug-shaped and authored — never a
        // path, never derived from a filename (§6.1).
        Route::get('packs/{slug}/versions/{version}/preview/{book}/{page}', [PackController::class, 'previewPage'])
            ->whereNumber('version')
            ->whereNumber('page')
            ->where('book', '[A-Za-z0-9._-]+')
            ->name('packs.versions.preview.page');

        Route::post('packs/{slug}/versions/{version}/publish', [PackController::class, 'publish'])
            ->whereNumber('version')
            ->name('packs.versions.publish');

        Route::post('entitlements', EntitlementController::class)->name('entitlements.store');
    });
