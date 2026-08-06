<?php

/*
|--------------------------------------------------------------------------
| Save sync — WP2 (progress) and WP4 (paint)
|--------------------------------------------------------------------------
|
| Loaded by routes/api.php inside the `/api/v1` + `api.v1.` name group.
|
| Planned surface (DLC_SERVER.md §11 "Sync"):
|
|   GET  /sync/progress?profile=&since=          WP2
|   PUT  /sync/progress                          WP2  batched, base_revision → 409
|   POST /sync/paint/{book_uid}/{page}           WP4  sha256 → 204 have-it / 202 upload
|   PUT  /sync/paint/{book_uid}/{page}           WP4  raw PNG, Content-Digest checked
|   GET  /sync/paint/{book_uid}/{page}           WP4  302 signed URL, or 404
|
| All of these require a token with the `save:sync` ability.
|
*/
