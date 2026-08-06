<?php

namespace App\Http\Middleware;

use App\Models\User;
use App\Services\DeviceTokens;
use Closure;
use Illuminate\Http\Request;
use Laravel\Sanctum\PersonalAccessToken;
use Symfony\Component\HttpFoundation\Response;

/**
 * "Refresh on any successful call" (DLC_SERVER.md §4.2), implemented once for
 * every API route in every work package.
 *
 * It runs as an *after* middleware — appended to the `api` group in
 * bootstrap/app.php — because at that point the route's own `auth:sanctum`
 * has already resolved the bearer token. Failed requests slide nothing: a
 * wrong-password attempt or a 403 must not keep a token alive.
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

        $user = $request->user();

        if (! $user instanceof User) {
            return $response;
        }

        $token = $user->currentAccessToken();

        // A session-backed dashboard request carries a TransientToken, which
        // has no expiry to slide.
        if (! $token instanceof PersonalAccessToken) {
            return $response;
        }

        if ($this->tokens->shouldSlide($token)) {
            $this->tokens->slide($token);
        }

        $device = $this->tokens->deviceFor($user, $token);

        if ($device !== null) {
            $this->tokens->touchDevice($device);
        }

        return $response;
    }
}
