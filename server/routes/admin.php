<?php

use App\Http\Controllers\Admin\EntitlementController;
use App\Http\Controllers\Admin\PackController;
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
| Non-admins get a **404**, not a 403: as far as an ordinary parent is
| concerned this section does not exist, and the sidebar never renders a link
| to it (see AppSidebar.vue).
|
| Not gated on `verified` — same reasoning as the parent dashboard
| (SERVER_BUILD_PLAN.md Q11): MAIL_MAILER is `log`, and locking the operator
| out of their own publishing tool behind an unread mail helps nobody.
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
    });
