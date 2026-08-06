<?php

use App\Http\Controllers\Api\V1\EntitlementController;
use App\Http\Controllers\Api\V1\PackController;
use App\Http\Controllers\Api\V1\PackDownloadController;
use App\Http\Middleware\OptionalSanctumUser;
use App\Http\Middleware\VerifySignedDownload;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| Catalog, entitlements & DLC delivery — WP3
|--------------------------------------------------------------------------
|
| Loaded by routes/api.php inside the `/api/v1` + `api.v1.` name group.
| Owned by WP3; no other work package edits this file.
|
| The surface (DLC_SERVER.md §11 "Catalog & DLC"):
|
|   GET  /packs                              optional auth, ?client_version=
|   GET  /packs/{slug}                       optional auth
|   GET  /packs/{slug}/manifest?version=     token + entitlement
|   GET  /packs/{slug}/download?version=     token + entitlement → 302 signed
|   GET  /packs/{slug}/files/{path}?version= token + entitlement (delta)
|   GET  /entitlements?client_version=       token — also the update check
|   POST /entitlements/verify                Phase 6 (payments), not built
|
| Three tiers of access, and the difference is the whole delivery design
| (§7.4):
|
|  1. **Optional auth.** The shop window. Signed out it lists published
|     packs; signed in it adds `owned`. `OptionalSanctumUser` exists because
|     `auth:sanctum` cannot express "authenticate if you can" — it 401s.
|
|  2. **Token + `packs:download` + entitlement.** Everything that names bytes.
|     These routes never *send* bytes: they answer `302` with a ten-minute
|     signed URL. Free packs grant themselves a `source = 'free'` row here,
|     on first ask (App\Services\Entitlements).
|
|  3. **Signed, no token.** The routes that move the bytes. The signature is
|     the authorisation, which is what lets Godot's
|     `HTTPRequest.download_file` stream a pack straight to disk without
|     carrying auth headers. Under Nginx these hand off with
|     `X-Accel-Redirect` (config `coloringbook.accel_redirect`) so an 8 MB
|     download never occupies a PHP worker.
|
| `{path}` is `.*` because a pack-relative path has slashes in it
| (`books/coyote-2026/page_01.png`). It is not a hole: the delta routes serve
| a path only if it is a key in that version's manifest `files` map.
|
*/

Route::middleware(OptionalSanctumUser::class)->group(function (): void {
    Route::get('packs', [PackController::class, 'index'])->name('packs.index');
    Route::get('packs/{slug}', [PackController::class, 'show'])->name('packs.show');
});

Route::middleware(['auth:sanctum', 'abilities:packs:download'])->group(function (): void {
    Route::get('packs/{slug}/manifest', [PackDownloadController::class, 'manifest'])
        ->name('packs.manifest');

    Route::get('packs/{slug}/download', [PackDownloadController::class, 'download'])
        ->name('packs.download');

    Route::get('packs/{slug}/files/{path}', [PackDownloadController::class, 'file'])
        ->where('path', '.*')
        ->name('packs.files');
});

Route::middleware(VerifySignedDownload::class)->group(function (): void {
    Route::get('packs/{slug}/v/{version}/archive', [PackDownloadController::class, 'archive'])
        ->whereNumber('version')
        ->name('packs.archive');

    Route::get('packs/{slug}/v/{version}/file/{path}', [PackDownloadController::class, 'deltaFile'])
        ->whereNumber('version')
        ->where('path', '.*')
        ->name('packs.file.signed');
});

Route::middleware(['auth:sanctum', 'abilities:entitlements:read'])->group(function (): void {
    Route::get('entitlements', EntitlementController::class)->name('entitlements.index');
});
