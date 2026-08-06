<?php

namespace App\Http\Middleware;

use App\Models\User;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * `users.is_admin`, and nothing more elaborate than that.
 *
 * The publishing tool is explicitly single-operator: no roles, no approval
 * chain, no workflow states beyond `draft → published → retired`
 * (DLC_SERVER.md §10.2). One boolean column is the whole authorisation model,
 * so one middleware is the whole enforcement.
 *
 * It sits behind two different front doors and answers each in its own idiom:
 *
 * - **`/api/v1/admin/*`** — `auth:sanctum` + `abilities:admin` have already
 *   run, so the caller holds a token that was deliberately minted for the
 *   pack-build script. A non-admin gets a `403 FORBIDDEN` in the house error
 *   shape.
 * - **`/admin/*`** (Inertia) — session auth. A non-admin gets a **404**: the
 *   admin section should not exist as far as an ordinary parent is concerned,
 *   and a 403 on a URL they never saw is an invitation to go looking.
 */
class EnsureAdmin
{
    /**
     * @param  Closure(Request): Response  $next
     */
    public function handle(Request $request, Closure $next): Response
    {
        $user = $request->user();

        if ($user instanceof User && $user->is_admin) {
            return $next($request);
        }

        abort($request->is('api/*') ? Response::HTTP_FORBIDDEN : Response::HTTP_NOT_FOUND);
    }
}
