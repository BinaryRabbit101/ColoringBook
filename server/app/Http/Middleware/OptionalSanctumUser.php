<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Symfony\Component\HttpFoundation\Response;

/**
 * "Auth: optional" — the shop window (DLC_SERVER.md §11 "Catalog & DLC").
 *
 * The catalog and the free-delivery routes must answer a client with no token
 * at all (free play sends no identifier) *and* add `owned: true` when a token
 * happens to be present. `auth:sanctum` cannot do
 * that — it 401s — so this resolves the guard by hand and only promotes it to
 * the default when it actually found someone.
 *
 * Promoting it matters: `$request->user()` then works normally downstream,
 * and `SlideTokenExpiry` slides the 90-day window on a browse the same way it
 * does on a sync. A missing, malformed or expired bearer token is simply an
 * anonymous request — never an error, because a child browsing the shop is
 * not a failure state.
 */
class OptionalSanctumUser
{
    public function handle(Request $request, Closure $next): Response
    {
        if (Auth::guard('sanctum')->check()) {
            Auth::shouldUse('sanctum');
        }

        return $next($request);
    }
}
