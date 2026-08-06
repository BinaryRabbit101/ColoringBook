<?php

use App\Exceptions\ApiExceptionRenderer;
use App\Http\Middleware\HandleAppearance;
use App\Http\Middleware\HandleInertiaRequests;
use App\Http\Middleware\SlideTokenExpiry;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Middleware\AddLinkHeadersForPreloadedAssets;
use Illuminate\Http\Request;
use Laravel\Sanctum\Http\Middleware\CheckAbilities;
use Laravel\Sanctum\Http\Middleware\CheckForAnyAbility;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        api: __DIR__.'/../routes/api.php',
        commands: __DIR__.'/../routes/console.php',
        health: '/up',
    )
    ->withMiddleware(function (Middleware $middleware): void {
        $middleware->encryptCookies(except: ['appearance', 'sidebar_state']);

        $middleware->web(append: [
            HandleAppearance::class,
            HandleInertiaRequests::class,
            AddLinkHeadersForPreloadedAssets::class,
        ]);

        // Runs *after* the route's own auth middleware has resolved the token,
        // so it applies to every API route in every work package: the 90-day
        // expiry slides forward and the device's last_seen_at is refreshed on
        // any successful authenticated call (DLC_SERVER.md §4.2).
        $middleware->api(append: [
            SlideTokenExpiry::class,
        ]);

        // Sanctum ships these but registers no aliases of its own.
        $middleware->alias([
            'abilities' => CheckAbilities::class,
            'ability' => CheckForAnyAbility::class,
        ]);
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        $exceptions->shouldRenderJsonWhen(
            fn (Request $request) => $request->is('api/*') || $request->expectsJson(),
        );

        // Every /api/* failure, from any work package, comes out as
        // {"error": {"code": "SNAKE_CASE", "message": "…"}}.
        $exceptions->render(new ApiExceptionRenderer);
    })->create();
