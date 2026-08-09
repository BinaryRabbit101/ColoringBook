<?php

use App\Http\Controllers\Api\V1\DeviceRegistrationController;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| The anonymous device tier — BL-52
|--------------------------------------------------------------------------
|
| Loaded by routes/api.php inside the `/api/v1` + `api.v1.` name group.
| Owned by BL-52; no other work package edits this file.
|
| The surface (DLC_SERVER.md §4.3, §11 "Auth"):
|
|   POST /device/register   none   {device_uid, device_name, platform}
|                                  → {token, abilities, expires_at, device}
|
| §11 files this row under "Auth" beside `POST /auth/token`, and it could have
| lived in routes/api/auth.php. It is its own file for the house reason: one
| owner per route file, so a WP1 change and a BL-52 change never touch the same
| lines. The wiring in routes/api.php is identical either way.
|
| `throttle:6,1` on top of the group's `throttle:60,1` — the two limiters
| stack, and this route mints a credential from nothing but a client-chosen
| string, so it gets the tighter of the two auth limits (design §4.2).
|
| Abilities: `entitlements:read` + `packs:download`, and **never** `save:sync`
| (`coloringbook.token.anonymous_abilities`). An anonymous device can own packs;
| it can never upload a child's artwork. That single omission is what keeps
| every request carrying a child's picture behind a parent account, which is
| the whole COPPA posture of §4.3.
|
| No auth by design, and the route is not a hole: it only ever finds-or-creates
| the `user_id IS NULL` row for a uid, so a uid already linked to an account is
| invisible here. Knowing somebody's device_uid earns a fresh empty identity.
|
*/

Route::middleware('throttle:6,1')->group(function (): void {
    Route::post('device/register', DeviceRegistrationController::class)->name('device.register');
});
