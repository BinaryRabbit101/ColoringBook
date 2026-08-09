<?php

use App\Http\Controllers\Api\V1\DeviceRegistrationController;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| Device identity — the only way a client authenticates
|--------------------------------------------------------------------------
|
| Loaded by routes/api.php inside the `/api/v1` + `api.v1.` name group.
|
| The surface (DLC_SERVER.md §4.3, §11 "Auth"):
|
|   POST /device/register   none   {device_uid, device_name, platform}
|                                  → {token, abilities, expires_at, device}
|
| **This contract is pinned.** The game client codes against exactly this
| shape; changing a field name here breaks every install in the field, and
| there is no second identity to fall back on.
|
| `throttle:6,1` on top of the group's `throttle:60,1` — the two limiters
| stack, and this route mints a credential from nothing but a client-chosen
| string, so it gets the tighter of the two auth limits (design §4.2).
|
| Abilities: `entitlements:read` + `packs:download`
| (`coloringbook.token.abilities`). That is the whole set a game token can
| carry — nothing here can publish a pack, and there is nothing else on the
| server for it to reach.
|
| No auth by design, and the route is not a hole. It is find-or-create, so
| knowing somebody's `device_uid` would hand an attacker that device's
| entitlements — which is exactly the same exposure as knowing their password
| would have been, and the uid is a 128-bit ULID the client never shows. It is
| also why there is no refresh route: a 401 is recovered by registering again.
|
*/

Route::middleware('throttle:6,1')->group(function (): void {
    Route::post('device/register', DeviceRegistrationController::class)->name('device.register');
});
