<?php

namespace App\Http\Middleware;

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
 * bootstrap/app.php — because at that point the route's own `auth:sanctum` has
 * already resolved the bearer token. Failed requests slide nothing: a
 * wrong-password attempt or a 403 must not keep a token alive.
 *
 * Since BL-52 the resolved identity may be a `Device` rather than a `User` —
 * an anonymous device token (§4.3). The 90-day sliding window is the same
 * window; only the way we find the device row differs.
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

        // `$request->user()` is a `User` **or** a `Device` since BL-52 (the
        // static analyser only knows about the auth provider's model, hence no
        // instanceof pair here). Both carry `HasApiTokens`, which is the only
        // thing this middleware needs from either; `deviceForIdentity` is where
        // the difference is read.
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

        $device = $this->tokens->deviceForIdentity($identity, $token);

        if ($device !== null) {
            $this->tokens->touchDevice($device);
        }

        return $response;
    }
}
