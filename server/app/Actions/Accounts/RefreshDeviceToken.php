<?php

namespace App\Actions\Accounts;

use App\Models\User;
use App\Services\DeviceTokens;
use Carbon\CarbonImmutable;
use Laravel\Sanctum\PersonalAccessToken;

/**
 * `POST /api/v1/auth/refresh` — an explicit "keep me signed in".
 *
 * The middleware already slides expiry on any successful call, but only once
 * the window is a day old. This endpoint is what a client calls on launch
 * when it wants a definite answer, so it always slides and always reports the
 * new expiry.
 */
class RefreshDeviceToken
{
    public function __construct(private readonly DeviceTokens $tokens) {}

    public function handle(User $user, PersonalAccessToken $token): CarbonImmutable
    {
        $expiresAt = $this->tokens->slide($token);

        $device = $this->tokens->deviceFor($user, $token);

        if ($device !== null) {
            $this->tokens->touchDevice($device, force: true);
        }

        return $expiresAt;
    }
}
