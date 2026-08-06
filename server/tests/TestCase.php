<?php

namespace Tests;

use App\Models\Device;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\TestCase as BaseTestCase;
use Laravel\Fortify\Features;

abstract class TestCase extends BaseTestCase
{
    protected function skipUnlessFortifyHas(string $feature, ?string $message = null): void
    {
        if (! Features::enabled($feature)) {
            $this->markTestSkipped($message ?? "Fortify feature [{$feature}] is not enabled.");
        }
    }

    /**
     * Start the next request with no memory of who was signed in.
     *
     * A real request builds its guards from scratch. In tests the container
     * survives from one call to the next, and Sanctum's `RequestGuard`
     * memoises the user it resolved — so without this, a token revoked
     * halfway through a test would carry on working and the test would prove
     * nothing. Call it between "revoke" and "try again".
     */
    protected function forgetResolvedGuards(): static
    {
        $this->app?->make('auth')->forgetGuards();

        return $this;
    }

    /**
     * Sign a device in the way `POST /auth/token` does, without going through
     * the endpoint: a device row plus a token named after its device_uid.
     *
     * Returns the bearer string, for `withToken(...)`.
     *
     * @param  array<int, string>|null  $abilities  defaults to the full game set
     */
    protected function issueDeviceToken(
        User $user,
        string $deviceUid = 'device-uid-primary',
        ?array $abilities = null,
        ?CarbonImmutable $expiresAt = null,
    ): string {
        Device::factory()->for($user)->create(['device_uid' => $deviceUid]);

        /** @var array<int, string> $default */
        $default = config('coloringbook.token.abilities');

        return $user->createToken(
            $deviceUid,
            $abilities ?? $default,
            $expiresAt ?? CarbonImmutable::now()->addDays((int) config('coloringbook.token.ttl_days')),
        )->plainTextToken;
    }
}
