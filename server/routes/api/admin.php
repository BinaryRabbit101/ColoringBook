<?php

use App\Http\Controllers\Api\V1\Admin\AssetController;
use App\Http\Controllers\Api\V1\Admin\BookController;
use App\Http\Controllers\Api\V1\Admin\BookPageController;
use App\Http\Controllers\Api\V1\Admin\EntitlementController;
use App\Http\Controllers\Api\V1\Admin\PackController;
use App\Http\Controllers\Api\V1\Admin\StickerController;
use App\Http\Controllers\Api\V1\Admin\StickerSetController;
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
| Web authoring (BL-24, §10.3 and §11's web-authoring table) adds book and page
| CRUD alongside the pack routes:
|
|   GET    /admin/books                             every authored book
|   POST   /admin/books                             create a book + its one-book pack
|   GET    /admin/books/{book}                      the book, with its pages
|   PATCH  /admin/books/{book}                      retitle
|   DELETE /admin/books/{book}                      delete, or retire once published
|   GET    /admin/books/{book}/pages                the page list
|   POST   /admin/books/{book}/pages                add a page (multipart or asset ulids)
|   GET    /admin/books/{book}/pages/{index}        one page
|   PATCH  /admin/books/{book}/pages/{index}        title / reorder / replace art
|   DELETE /admin/books/{book}/pages/{index}        remove a page and close the gap
|   GET    /admin/books/{book}/pages/{index}/status mapping state + §10.1 verdict
|   GET    .../pages/{index}/preview                the region-overlay PNG
|   POST   /admin/books/{book}/publish              build + validate + publish a version
|
| `{book}` is a `book_uid`: authored, slug-shaped, stable forever (§6.1).
| `{index}` is the page's 0-based position in its book, as everywhere else on
| this API. §11 lists one `preview`; it is a separate route here for the same
| reason the pack preview is — a page list is JSON and an overlay is a PNG.
|
| ## Auth: two doors, one boolean
|
| This is the **token** door — a Sanctum token carrying the `admin` ability,
| which the dev box's `pack build` script POSTs with. It is minted by hand
| (`php artisan admin:token you@example.com`) and never by the game: a device
| token holds exactly `entitlements:read` + `packs:download` and can no more
| publish a pack than sell one.
|
| The **session** door is `routes/admin.php`, the Inertia UI, where a signed-in
| operator with `is_admin` gets the same actions through forms. `EnsureAdmin`
| is the single `users.is_admin` check behind both; it 403s here and 404s
| there. `users` holds operators only — there is no player account to hide it
| from any more — but the 404 costs nothing and stays.
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

        // ------------------------------------------------- web authoring ---
        Route::get('books', [BookController::class, 'index'])->name('books.index');
        Route::post('books', [BookController::class, 'store'])->name('books.store');

        Route::prefix('books/{book}')
            ->name('books.')
            ->where(['book' => '[a-z0-9][a-z0-9._-]*'])
            ->group(function (): void {
                Route::get('/', [BookController::class, 'show'])->name('show');
                Route::patch('/', [BookController::class, 'update'])->name('update');
                Route::delete('/', [BookController::class, 'destroy'])->name('destroy');

                // BL-38: the artist's optional cover art. Uploaded on the book
                // PATCH (multipart `cover`, or `cover_asset_ulid`), cleared with
                // `remove_cover`, and read back here.
                Route::get('cover', [BookController::class, 'cover'])->name('cover');

                Route::post('publish', [BookController::class, 'publish'])->name('publish');

                Route::get('pages', [BookPageController::class, 'index'])->name('pages.index');
                Route::post('pages', [BookPageController::class, 'store'])->name('pages.store');

                Route::prefix('pages/{index}')
                    ->name('pages.')
                    ->whereNumber('index')
                    ->group(function (): void {
                        Route::get('/', [BookPageController::class, 'show'])->name('show');
                        Route::patch('/', [BookPageController::class, 'update'])->name('update');
                        Route::delete('/', [BookPageController::class, 'destroy'])->name('destroy');
                        Route::get('status', [BookPageController::class, 'status'])->name('status');
                        Route::get('preview', [BookPageController::class, 'preview'])->name('preview');

                        // BL-38: the page's own uploads, as files. `preview` is
                        // the composited region overlay; these are the art.
                        Route::get('display', [BookPageController::class, 'display'])->name('display');
                        Route::get('mask', [BookPageController::class, 'mask'])->name('mask');
                    });
            });

        // ------------------------------------------ sticker sets (BL-37) ---
        // The same authoring surface, one content kind over. `{set}` is a
        // `set_uid` — authored, slug-shaped, stable forever, and named by every
        // sticker a child has already stuck on a page (BL-36's save shape).
        // There is deliberately no `status` route and no polling: a sticker has
        // no regions, so there is no mapping job to wait for.
        Route::get('sticker-sets', [StickerSetController::class, 'index'])->name('sticker-sets.index');
        Route::post('sticker-sets', [StickerSetController::class, 'store'])->name('sticker-sets.store');

        Route::prefix('sticker-sets/{set}')
            ->name('sticker-sets.')
            ->where(['set' => '[a-z0-9][a-z0-9._-]*'])
            ->group(function (): void {
                Route::get('/', [StickerSetController::class, 'show'])->name('show');
                Route::patch('/', [StickerSetController::class, 'update'])->name('update');
                Route::delete('/', [StickerSetController::class, 'destroy'])->name('destroy');

                Route::post('publish', [StickerSetController::class, 'publish'])->name('publish');

                Route::get('stickers', [StickerController::class, 'index'])->name('stickers.index');
                Route::post('stickers', [StickerController::class, 'store'])->name('stickers.store');

                Route::prefix('stickers/{index}')
                    ->name('stickers.')
                    ->whereNumber('index')
                    ->group(function (): void {
                        Route::get('/', [StickerController::class, 'show'])->name('show');
                        Route::patch('/', [StickerController::class, 'update'])->name('update');
                        Route::delete('/', [StickerController::class, 'destroy'])->name('destroy');
                        Route::get('image', [StickerController::class, 'image'])->name('image');
                    });
            });
    });
