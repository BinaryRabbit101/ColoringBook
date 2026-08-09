<?php

use App\Http\Controllers\Admin\BookController;
use App\Http\Controllers\Admin\BookPageController;
use App\Http\Controllers\Admin\EntitlementController;
use App\Http\Controllers\Admin\PackController;
use App\Http\Controllers\Admin\StickerController;
use App\Http\Controllers\Admin\StickerSetController;
use App\Http\Middleware\EnsureAdmin;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| Admin dashboard (Inertia) — WP5
|--------------------------------------------------------------------------
|
| The session door onto the publishing tool. `routes/api/admin.php` is the
| token door, for the dev box's `pack build` script; both stand behind the
| same `EnsureAdmin` (users.is_admin) and call the same actions.
|
| Non-admins get a **404**, not a 403: as far as a signed-in non-operator is
| concerned this section does not exist, and the sidebar never renders a link
| to it (see AppSidebar.vue).
|
| Not gated on `verified`: MAIL_MAILER is `log` (SERVER_BUILD_PLAN.md Q11), and
| locking the operator out of their own publishing tool behind an unread mail
| helps nobody. Email verification is not a Fortify feature here at all.
|
*/

Route::middleware(['auth', EnsureAdmin::class])
    ->prefix('admin')
    ->name('admin.')
    ->group(function (): void {
        Route::get('packs', [PackController::class, 'index'])->name('packs.index');
        Route::post('packs', [PackController::class, 'store'])->name('packs.store');
        Route::get('packs/{slug}', [PackController::class, 'show'])->name('packs.show');

        Route::post('packs/{slug}/versions', [PackController::class, 'storeVersion'])
            ->name('packs.versions.store');

        Route::get('packs/{slug}/versions/{version}/preview', [PackController::class, 'preview'])
            ->whereNumber('version')
            ->name('packs.versions.preview');

        Route::get('packs/{slug}/versions/{version}/preview/{book}/{page}', [PackController::class, 'previewPage'])
            ->whereNumber('version')
            ->whereNumber('page')
            ->where('book', '[A-Za-z0-9._-]+')
            ->name('packs.versions.preview.page');

        Route::post('packs/{slug}/versions/{version}/publish', [PackController::class, 'publish'])
            ->whereNumber('version')
            ->name('packs.versions.publish');

        Route::get('entitlements', [EntitlementController::class, 'index'])->name('entitlements.index');
        Route::post('entitlements', [EntitlementController::class, 'store'])->name('entitlements.store');

        /*
        | Web authoring (BL-24, §10.3). Mirrors the token door in
        | routes/api/admin.php route for route, plus the two GETs a browser
        | needs and a script does not: the book screen and the page editor.
        */
        Route::get('books', [BookController::class, 'index'])->name('books.index');
        Route::post('books', [BookController::class, 'store'])->name('books.store');

        Route::prefix('books/{book}')
            ->name('books.')
            ->where(['book' => '[a-z0-9][a-z0-9._-]*'])
            ->group(function (): void {
                Route::get('/', [BookController::class, 'show'])->name('show');
                Route::patch('/', [BookController::class, 'update'])->name('update');
                Route::delete('/', [BookController::class, 'destroy'])->name('destroy');

                // BL-38: the artist's cover art, as an <img src> target. The
                // upload rides the book PATCH beside the title.
                Route::get('cover', [BookController::class, 'cover'])->name('cover');

                Route::post('publish', [BookController::class, 'publish'])->name('publish');

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

                        // BL-38: the page's own art, for the book screen's
                        // thumbnails. `preview` composites the region overlay;
                        // these two are the files themselves.
                        Route::get('display', [BookPageController::class, 'display'])->name('display');
                        Route::get('mask', [BookPageController::class, 'mask'])->name('mask');
                    });
            });

        /*
        | Sticker sets (BL-37). The same authoring surface one content kind
        | over, mirroring the token door route for route. There is no per-sticker
        | editor screen: a sticker is an id and a picture, and the set screen
        | shows every one of them at once, which is how a sticker sheet is
        | actually reviewed.
        */
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

                Route::post('stickers', [StickerController::class, 'store'])->name('stickers.store');

                Route::prefix('stickers/{index}')
                    ->name('stickers.')
                    ->whereNumber('index')
                    ->group(function (): void {
                        Route::patch('/', [StickerController::class, 'update'])->name('update');
                        Route::delete('/', [StickerController::class, 'destroy'])->name('destroy');
                        Route::get('image', [StickerController::class, 'image'])->name('image');
                    });
            });
    });
