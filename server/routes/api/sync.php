<?php

use App\Http\Controllers\Api\V1\ProgressSyncController;
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
|   POST /sync/paint/{book_uid}/{page}           WP4  sha256 → 204 have-it / 202 upload
|   PUT  /sync/paint/{book_uid}/{page}           WP4  raw PNG, Content-Digest checked
|   GET  /sync/paint/{book_uid}/{page}           WP4  302 signed URL, or 404
|
| All of these require a token with the `save:sync` ability.
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
    |----------------------------------------------------------------------
    | Paint layers — WP4
    |----------------------------------------------------------------------
    |
    | WP4 adds the three /sync/paint/{book_uid}/{page} routes here. They hang
    | off the same `book_progress` row this file's progress routes maintain
    | (paint_layers.book_progress_id, design §5), so a paint upload for a book
    | the shelf has never synced has to create or find that row first.
    |
    */

});
