<?php

namespace App\Services;

use App\Models\Device;
use Carbon\CarbonImmutable;
use Laravel\Sanctum\PersonalAccessToken;

/**
 * Everything the 90-day sliding device token knows how to do.
 *
 * The rule (DLC_SERVER.md §4.2): a token issued to a device expires 90 days
 * after its last successful use. Rewriting `expires_at` on every request would
 * be a write per API call, so the window only slides once it is
 * `slide_after_days` old — the player-visible behaviour is identical and the
 * database stays quiet. All of it is config-driven via `coloringbook.token`.
 *
 * There is exactly one kind of game token now: minted on a `Device` row by
 * `POST /api/v1/device/register`, named after the client's `device_uid`, and
 * carrying `entitlements:read` + `packs:download`. A client that gets a 401
 * simply registers again — the endpoint is find-or-create, so re-auth is
 * idempotent and there is no refresh route to keep alive.
 */
class DeviceTokens
{
    /**
     * The abilities every device token is issued with. Nothing here can publish
     * a pack (`admin` is minted only by `php artisan admin:token`) and nothing
     * here can reach a route that isn't the catalog or the entitlement list.
     *
     * @return array<int, string>
     */
    public function abilities(): array
    {
        /** @var array<int, string> $abilities */
        $abilities = config('coloringbook.token.abilities');

        return $abilities;
    }

    /**
     * The full-length expiry for a token used right now.
     */
    public function expiresAt(?CarbonImmutable $from = null): CarbonImmutable
    {
        return ($from ?? CarbonImmutable::now())->addDays($this->ttlDays());
    }

    /**
     * Has this token's window aged past the slide threshold?
     *
     * A token with no expiry (there shouldn't be any, but a hand-made one in
     * tinker would qualify) is left exactly as it is.
     */
    public function shouldSlide(PersonalAccessToken $token): bool
    {
        if ($token->expires_at === null) {
            return false;
        }

        $slideAfter = (int) config('coloringbook.token.slide_after_days');

        // The window opened `ttl` days before it closes; slide once we're
        // `slide_after_days` past that point.
        return CarbonImmutable::createFromInterface($token->expires_at)
            ->subDays($this->ttlDays())
            ->addDays($slideAfter)
            ->isPast();
    }

    /**
     * Push the expiry out to a full window from now.
     */
    public function slide(PersonalAccessToken $token): CarbonImmutable
    {
        $expiresAt = $this->expiresAt();

        $token->forceFill(['expires_at' => $expiresAt])->save();

        return $expiresAt;
    }

    /**
     * The device behind a resolved `auth:sanctum` identity, or null.
     *
     * A device token is minted on the device row itself, so the tokenable *is*
     * the device and there is nothing to look up. An **admin** token hangs off a
     * `User` and has no device at all, which is what the null covers.
     */
    public function deviceForIdentity(mixed $identity): ?Device
    {
        return $identity instanceof Device ? $identity : null;
    }

    /**
     * Mark the device as seen, unless we already did so recently.
     */
    public function touchDevice(Device $device, bool $force = false): void
    {
        $after = (int) config('coloringbook.token.touch_device_after_minutes');

        $isStale = $device->last_seen_at === null
            || CarbonImmutable::createFromInterface($device->last_seen_at)
                ->addMinutes($after)
                ->isPast();

        if ($force || $isStale) {
            $device->forceFill(['last_seen_at' => CarbonImmutable::now()])->save();
        }
    }

    private function ttlDays(): int
    {
        return (int) config('coloringbook.token.ttl_days');
    }
}
