<?php

use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| API routes — /api/v1
|--------------------------------------------------------------------------
|
| This file only wires up the per-domain route files. Nothing else belongs
| here: parallel work packages each own one file under routes/api/ so two
| agents never edit the same route file (SERVER_BUILD_PLAN.md, "House
| conventions").
|
| The version lives in the path because old game builds stay on players'
| devices forever (DLC_SERVER.md §11).
|
| `throttle:60,1` is the baseline for every v1 route. Auth routes tighten
| that to `throttle:6,1` inside routes/api/auth.php — the two limiters stack.
|
*/

Route::prefix('v1')
    ->name('api.v1.')
    ->middleware('throttle:60,1')
    ->group(function (): void {
        require __DIR__.'/api/auth.php';
        require __DIR__.'/api/device.php';
        require __DIR__.'/api/sync.php';
        require __DIR__.'/api/catalog.php';
        require __DIR__.'/api/admin.php';
    });
