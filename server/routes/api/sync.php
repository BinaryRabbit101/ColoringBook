<?php

use App\Http\Controllers\Api\V1\PaintSyncController;
use App\Http\Controllers\Api\V1\ProgressSyncController;
use App\Http\Middleware\VerifySignedDownload;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| Save sync — WP2 (progress) and WP4 (paint)
|--------------------------------------------------------------------------
|
| Loaded by routes/api.php inside the `/api/v1` + `api.v1.` name group.
|
| Planned surface (DLC_SERVER.md §11 "Sync"):
|
|   GET  /sync/progress?profile=&since=          WP2  ✅
|   PUT  /sync/progress                          WP2  ✅ batched, base_revision
|   DELETE /sync/progress                        BL-18 ✅ wipe the shelf, stamp the clock
|   POST /sync/paint/{book_uid}/{page}           WP4  ✅ sha256 → 204 have-it / 202 upload
|   PUT  /sync/paint/{book_uid}/{page}           WP4  ✅ raw PNG, Content-Digest checked
|   GET  /sync/paint/{book_uid}/{page}           WP4  ✅ 302 signed URL, or 404
|   DELETE /sync/paint/{book_uid}/{page}         BL-18 ✅ "Start over", as a state
|   GET  /sync/paint/{book_uid}                  WP4  ✅ per-page paint metadata (added)
|
| All of these require a token with the `save:sync` ability. The signed blob
| route at the bottom of this file is the one exception, and the reason is
| written there.
|
| This file is shared by two work packages, so each keeps to its own block
| below. The sliding token expiry and the `devices.last_seen_at` touch are
| after-middleware on the whole `api` group — nothing here has to ask for them.
|
*/

Route::middleware(['auth:sanctum', 'abilities:save:sync'])->group(function (): void {

    /*
    |----------------------------------------------------------------------
    | Progress — WP2
    |----------------------------------------------------------------------
    |
    | One row per (account, child, book). Conflicts are encoded per book
    | inside a 200 rather than as a whole-request 409 — see
    | ProgressSyncController and the WP2 section of server/CLAUDE.md.
    |
    */

    Route::get('sync/progress', [ProgressSyncController::class, 'index'])->name('sync.progress.index');
    Route::put('sync/progress', [ProgressSyncController::class, 'update'])->name('sync.progress.update');

    /*
     * BL-18 — "Erase all progress", pushed up rather than left local.
     *
     * The merge only ever climbs, so an erasure cannot be expressed as an
     * absence: this wipes the shelf's rows AND records the instant it did, and
     * `GET` publishes that instant so every other device censors itself
     * against it. See DLC_SERVER.md §6.3 "Erasure".
     */
    Route::delete('sync/progress', [ProgressSyncController::class, 'destroy'])
        ->name('sync.progress.destroy');

    /*
    |----------------------------------------------------------------------
    | Paint layers — WP4
    |----------------------------------------------------------------------
    |
    | They hang off the same `book_progress` row this file's progress routes
    | maintain (paint_layers.book_progress_id, design §5), so a paint upload
    | for a book the shelf has never synced creates that row first — the PUT
    | does, at revision 1 with no page statuses; the POST and the GETs never
    | write anything.
    |
    | `{book_uid}` is authored and slug-shaped (§6.1); `{page}` is the 0-based
    | page *index*, the same numbering as `page_statuses`. The file on disk is
    | 1-based (`page_01.png`) to match what the client already writes to
    | `user://paint/<slug>/` — see App\Services\PaintStorage.
    |
    */

    Route::get('sync/paint/{book_uid}', [PaintSyncController::class, 'index'])
        ->name('sync.paint.index');

    Route::post('sync/paint/{book_uid}/{page}', [PaintSyncController::class, 'negotiate'])
        ->whereNumber('page')
        ->name('sync.paint.negotiate');

    Route::put('sync/paint/{book_uid}/{page}', [PaintSyncController::class, 'upload'])
        ->whereNumber('page')
        ->name('sync.paint.upload');

    Route::get('sync/paint/{book_uid}/{page}', [PaintSyncController::class, 'show'])
        ->whereNumber('page')
        ->name('sync.paint.show');

    /*
     * BL-18 — the page's "Start over" (BL-7), pushed as a state. Deletes the
     * picture under the same LWW rule an upload obeys, and stamps the page's
     * erase clock so its status cannot climb back to `complete` either.
     */
    Route::delete('sync/paint/{book_uid}/{page}', [PaintSyncController::class, 'destroy'])
        ->whereNumber('page')
        ->name('sync.paint.destroy');

});

/*
|--------------------------------------------------------------------------
| Paint blobs — WP4, signed rather than authenticated
|--------------------------------------------------------------------------
|
| Outside the token group on purpose, and the only route in this file that
| is. `GET /sync/paint/{book}/{page}` authorises and then `302`s here with a
| ten-minute signature, so the transfer itself is a plain unauthenticated GET
| that `HTTPRequest.download_file` can stream straight into `user://paint/`
| without minding headers — the same two-step WP3 uses for packs (§7.4), and
| the same `X-Accel-Redirect` hand-off under Nginx.
|
| Spelled `paint-blob` rather than `paint/blob` so no authored `book_uid`
| could ever be read as this route.
|
*/

Route::middleware(VerifySignedDownload::class)->group(function (): void {
    Route::get('sync/paint-blob/{layer}', [PaintSyncController::class, 'blob'])
        ->name('sync.paint.blob');
});
