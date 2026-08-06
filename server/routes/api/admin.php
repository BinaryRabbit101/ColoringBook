<?php

/*
|--------------------------------------------------------------------------
| Admin — WP5
|--------------------------------------------------------------------------
|
| Loaded by routes/api.php inside the `/api/v1` + `api.v1.` name group.
| Owned by WP5; no other work package edits this file.
|
| Everything here is gated on `users.is_admin`. It is a single-operator tool:
| no roles, no approval chain (DLC_SERVER.md §10.2).
|
| Planned surface (DLC_SERVER.md §11 "Admin"):
|
|   POST /admin/assets                              multipart, content-addressed
|   POST /admin/packs                               create a draft pack
|   POST /admin/packs/{slug}/versions               zip or manifest+ulids → validation
|   GET  /admin/packs/{slug}/versions/{v}/preview   region-overlay preview
|   POST /admin/packs/{slug}/versions/{v}/publish   flips published_at
|   POST /admin/entitlements                        promo grant by email
|
*/
