<?php

namespace Tests;

use App\Actions\Devices\IssuedDeviceToken;
use App\Actions\Devices\RegisterDevice;
use App\Models\Device;
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
     * Put the default guard back to the session one.
     *
     * `auth:sanctum` calls `shouldUse('sanctum')`, which rewrites
     * `auth.defaults.guard` **for the rest of the process**. In a test the
     * container survives between calls, so after any API request a bare `auth`
     * (session) route will happily accept a bearer token and a "a game token
     * cannot do this" test silently passes for the wrong reason. Call this
     * between an API call and a dashboard call.
     */
    protected function useSessionGuard(): static
    {
        $this->app?->make('auth')->shouldUse('web');

        return $this->forgetResolvedGuards();
    }

    /**
     * Register a device exactly the way `POST /api/v1/device/register` does.
     *
     * Goes through the real action rather than hand-rolling a token, so a test
     * that uses it also proves the abilities are the ones the endpoint issues
     * and the token really is minted on the device row.
     */
    protected function registerDevice(
        string $deviceUid = 'device-uid-primary',
        ?string $deviceName = null,
        ?string $platform = null,
    ): IssuedDeviceToken {
        return app(RegisterDevice::class)->handle($deviceUid, $deviceName, $platform);
    }

    /**
     * A bearer token for a device, without going through the endpoint.
     *
     * Omit `$device` for a fresh one — `DeviceFactory` mints a random uid, so
     * two calls in one test are two devices rather than a unique-index
     * collision. Pass `$abilities` to build a token that is deliberately
     * missing one, which is how the `abilities:` gates are tested.
     */
    protected function issueDeviceToken(
        ?Device $device = null,
        ?array $abilities = null,
        ?CarbonImmutable $expiresAt = null,
    ): string {
        $device ??= Device::factory()->create();

        /** @var array<int, string> $default */
        $default = config('coloringbook.token.abilities');

        return $device->createToken(
            $device->device_uid,
            $abilities ?? $default,
            $expiresAt ?? CarbonImmutable::now()->addDays((int) config('coloringbook.token.ttl_days')),
        )->plainTextToken;
    }
}
