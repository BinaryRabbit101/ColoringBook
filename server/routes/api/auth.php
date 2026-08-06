<?php

use App\Http\Controllers\Api\V1\ChildProfileController;
use App\Http\Controllers\Api\V1\MeController;
use App\Http\Controllers\Api\V1\RegisterController;
use App\Http\Controllers\Api\V1\TokenController;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| Auth & profiles — WP1
|--------------------------------------------------------------------------
|
| Loaded by routes/api.php inside the `/api/v1` + `api.v1.` name group.
| Owned by WP1; no other work package edits this file.
|
| The surface (DLC_SERVER.md §11 "Auth" and "Profiles"):
|
|   POST   /auth/register        none    {email, password, is_guardian:true}
|   POST   /auth/token           none    device-scoped Sanctum token
|   POST   /auth/refresh         token   slides expiry
|   DELETE /auth/token           token   sign out this device
|   GET    /me                   token   {user, profiles[], devices[]}
|   GET|POST      /profiles      token
|   PATCH|DELETE  /profiles/{ulid}  token
|
| The unauthenticated pair add `throttle:6,1` on top of the group's
| `throttle:60,1` — the two limiters stack (design §4.2).
|
| Abilities. Every game token is issued with exactly `save:sync`,
| `entitlements:read`, `packs:download`. `/me` and the profile routes are
| gated on `save:sync`: they are part of the save surface a playing device
| legitimately needs. Refresh and sign-out need no ability — any live token
| may end or extend its own life. Nothing here can delete the account, change
| the password or revoke *another* device; those are web-dashboard only,
| behind a password re-confirmation (design §4.2).
|
*/

Route::middleware('throttle:6,1')->group(function (): void {
    Route::post('auth/register', RegisterController::class)->name('auth.register');
    Route::post('auth/token', [TokenController::class, 'store'])->name('auth.token.store');
});

Route::middleware('auth:sanctum')->group(function (): void {
    Route::post('auth/refresh', [TokenController::class, 'refresh'])->name('auth.refresh');
    Route::delete('auth/token', [TokenController::class, 'destroy'])->name('auth.token.destroy');

    Route::middleware('abilities:save:sync')->group(function (): void {
        Route::get('me', MeController::class)->name('me');

        Route::get('profiles', [ChildProfileController::class, 'index'])->name('profiles.index');
        Route::post('profiles', [ChildProfileController::class, 'store'])->name('profiles.store');
        Route::patch('profiles/{profile}', [ChildProfileController::class, 'update'])->name('profiles.update');
        Route::delete('profiles/{profile}', [ChildProfileController::class, 'destroy'])->name('profiles.destroy');
    });
});
