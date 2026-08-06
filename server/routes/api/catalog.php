<?php

/*
|--------------------------------------------------------------------------
| Catalog, entitlements & DLC delivery — WP3
|--------------------------------------------------------------------------
|
| Loaded by routes/api.php inside the `/api/v1` + `api.v1.` name group.
| Owned by WP3; no other work package edits this file.
|
| Planned surface (DLC_SERVER.md §11 "Catalog & DLC"):
|
|   GET  /packs                              optional auth, ?client_version=
|   GET  /packs/{slug}                       optional auth
|   GET  /packs/{slug}/manifest?version=     token + entitlement
|   GET  /packs/{slug}/download?version=     token + entitlement → 302 signed
|   GET  /packs/{slug}/files/{path}?version= token + entitlement (delta)
|   GET  /entitlements                       token — also the update check
|   POST /entitlements/verify                token — Phase 6, not this campaign
|
| Download routes honour config('coloringbook.accel_redirect').
|
*/
