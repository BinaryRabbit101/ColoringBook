<?php

use App\Http\Controllers\Api\V1\EntitlementController;
use App\Http\Controllers\Api\V1\PackController;
use App\Http\Controllers\Api\V1\PackCoverController;
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
|   GET  /packs/{slug}/manifest?version=     public if free, else token + entitlement
|   GET  /packs/{slug}/download?version=     public if free, else token + entitlement
|   GET  /packs/{slug}/files/{path}?version= public if free, else token + entitlement
|   GET  /entitlements?client_version=       token — also the update check
|   POST /entitlements/verify                token — store receipt → entitlement
|
| Three tiers of access, and the difference is the whole delivery design
| (§7.4):
|
|  1. **Optional auth.** The shop window, and — since BL-52 — the three
|     delivery routes too. Signed out, the shop lists published packs and the
|     delivery routes serve **free** ones; signed in, the shop adds `owned`
|     and the delivery routes also serve what the token's owner has bought.
|     `OptionalSanctumUser` exists because `auth:sanctum` cannot express
|     "authenticate if you can" — it 401s.
|
|  2. **Paid: token + `packs:download` + entitlement.** Everything that names
|     bytes and isn't free. These routes never *send* bytes: they answer `302`
|     with a ten-minute signed URL. The gate now lives in
|     `PackDownloadController::authorised()` rather than in route middleware,
|     because it has to depend on the pack. Free packs still grant themselves a
|     `source = 'free'` row when a token is present (App\Services\Entitlements)
|     — that row is what `owned` and `GET /entitlements` mean, and it is no
|     longer what the gate reads.
|
|  3. **Signed, no token.** The routes that move the bytes. The signature is
|     the authorisation, which is what lets Godot's
|     `HTTPRequest.download_file` stream a pack straight to disk without
|     carrying auth headers. Under Nginx these hand off with
|     `X-Accel-Redirect` (config `coloringbook.accel_redirect`) so an 8 MB
|     download never occupies a PHP worker. **Untouched by BL-52**: making free
|     packs public changed who may ask for a signed URL, not what one is.
|
| `/entitlements` and `/entitlements/verify` accept an account token **or** an
| anonymous device token (BL-52, §4.3) and read/write the rows of whichever
| owner the bearer names. They gate on the `entitlements:read` ability, never on
| the kind of identity — which is also why nothing here can reach `/sync/*`: an
| anonymous token simply never carries `save:sync`.
|
| `{path}` is `.*` because a pack-relative path has slashes in it
| (`books/coyote-2026/page_01.png`). It is not a hole: the delta routes serve
| a path only if it is a key in that version's manifest `files` map.
|
*/

Route::middleware(OptionalSanctumUser::class)->group(function (): void {
    Route::get('packs', [PackController::class, 'index'])->name('packs.index');
    Route::get('packs/{slug}', [PackController::class, 'show'])->name('packs.show');

    /*
     * Delivery (BL-52). Optional auth rather than `auth:sanctum`, because
     * whether a token is required depends on the pack: a free one is public and
     * a paid one is not, and only the controller knows which this is. The
     * ability check and the entitlement check moved in with it — see
     * PackDownloadController::authorised().
     */
    Route::get('packs/{slug}/manifest', [PackDownloadController::class, 'manifest'])
        ->name('packs.manifest');

    Route::get('packs/{slug}/download', [PackDownloadController::class, 'download'])
        ->name('packs.download');

    Route::get('packs/{slug}/files/{path}', [PackDownloadController::class, 'file'])
        ->where('path', '.*')
        ->name('packs.files');
});

/*
 * Public, unauthenticated, no signature — the shop's thumbnail (WP5).
 *
 * Every other pack byte needs a token plus an entitlement, which is exactly
 * wrong for a cover: the point of the shop is to show packs a household does
 * *not* own. Listable packs only, so a draft's cover is never a product.
 * See App\Http\Controllers\Api\V1\PackCoverController for why this is a route
 * rather than a copy on the `public` disk.
 */
Route::get('packs/{slug}/cover', PackCoverController::class)->name('packs.cover');

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
    Route::get('entitlements', [EntitlementController::class, 'index'])->name('entitlements.index');
    Route::post('entitlements/verify', [EntitlementController::class, 'verify'])->name('entitlements.verify');
});
