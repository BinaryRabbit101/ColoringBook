<?php

namespace App\Actions\Devices;

use App\Models\Device;
use Carbon\CarbonImmutable;

/**
 * What `POST /api/v1/device/register` hands back — the one and only moment the
 * plain-text token exists.
 */
class IssuedDeviceToken
{
    /**
     * @param  array<int, string>  $abilities
     */
    public function __construct(
        public readonly string $plainTextToken,
        public readonly array $abilities,
        public readonly CarbonImmutable $expiresAt,
        public readonly Device $device,
    ) {}
}
