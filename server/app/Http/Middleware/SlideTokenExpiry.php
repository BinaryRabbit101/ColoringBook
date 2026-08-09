<?php

namespace App\Http\Middleware;

use App\Services\DeviceTokens;
use Closure;
use Illuminate\Http\Request;
use Laravel\Sanctum\PersonalAccessToken;
use Symfony\Component\HttpFoundation\Response;

/**
 * "Refresh on any successful call" (DLC_SERVER.md §4.2), implemented once for
 * every API route.
 *
 * It runs as an *after* middleware — appended to the `api` group in
 * bootstrap/app.php — because at that point the route's own `auth:sanctum` has
 * already resolved the bearer token. Failed requests slide nothing: a 401 or a
 * 403 must not keep a token alive.
 *
 * The resolved identity is a `Device` for a game token and a `User` for an
 * admin token. Both carry `HasApiTokens`, which is the only thing this
 * middleware needs from either; `deviceForIdentity()` is where the difference
 * is read, and it is also why there is no `instanceof` pair here — Larastan
 * types `$request->user()` from `auth.providers.users.model` and would call the
 * `Device` branch impossible.
 */
class SlideTokenExpiry
{
    public function __construct(private readonly DeviceTokens $tokens) {}

    public function handle(Request $request, Closure $next): Response
    {
        /** @var Response $response */
        $response = $next($request);

        if ($response->getStatusCode() >= 400) {
            return $response;
        }

        $identity = $request->user();

        if ($identity === null) {
            return $response;
        }

        $token = $identity->currentAccessToken();

        // A session-backed dashboard request carries a TransientToken, which
        // has no expiry to slide.
        if (! $token instanceof PersonalAccessToken) {
            return $response;
        }

        if ($this->tokens->shouldSlide($token)) {
            $this->tokens->slide($token);
        }

        $device = $this->tokens->deviceForIdentity($identity);

        if ($device !== null) {
            $this->tokens->touchDevice($device);
        }

        return $response;
    }
}
