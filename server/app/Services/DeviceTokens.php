<?php

namespace App\Services;

use App\Models\Device;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Collection;
use Laravel\Sanctum\PersonalAccessToken;

/**
 * Everything the 90-day sliding device token knows how to do.
 *
 * The rule (DLC_SERVER.md §4.2): a token issued to a device expires 90 days
 * after its last successful use. Rewriting `expires_at` on every request would
 * be a write per API call, so the window only slides once it is
 * `slide_after_days` old — the player-visible behaviour is identical and the
 * database stays quiet. All of it is config-driven via `coloringbook.token`.
 */
class DeviceTokens
{
    /**
     * The abilities every game token is issued with. Nothing here can mutate
     * the account: deleting it, changing the password or revoking another
     * device is web-dashboard-only, behind a password re-confirmation.
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
     * What an **anonymous** device token carries (BL-52, §4.3): the set above
     * minus `save:sync`, and that omission is the whole compliance story. An
     * anonymous device may own packs and download them; it can never upload a
     * child's artwork, so the only identifier the server ever holds without an
     * account behind it is used solely to authenticate content the device
     * already bought.
     *
     * @return array<int, string>
     */
    public function anonymousAbilities(): array
    {
        /** @var array<int, string> $abilities */
        $abilities = config('coloringbook.token.anonymous_abilities');

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
     * The device a token belongs to. Tokens are *named* after the device_uid,
     * which is the only link between Sanctum's table and ours.
     */
    public function deviceFor(User $user, PersonalAccessToken $token): ?Device
    {
        return Device::query()
            ->where('user_id', $user->id)
            ->where('device_uid', $token->name)
            ->first();
    }

    /**
     * The device behind a resolved identity, whichever kind it is (BL-52).
     *
     * An **anonymous** device token is minted on the device itself, so the
     * tokenable *is* the device and there is nothing to look up. A linked
     * device's token hangs off the user, and the name → `device_uid` link is
     * the only thing that ties Sanctum's table to ours.
     */
    public function deviceForIdentity(mixed $identity, PersonalAccessToken $token): ?Device
    {
        if ($identity instanceof Device) {
            return $identity;
        }

        return $identity instanceof User ? $this->deviceFor($identity, $token) : null;
    }

    /**
     * The account's devices, each flagged with whether a live (unexpired)
     * token still exists for it. That flag is what the dashboard's "sign this
     * device out" button switches off.
     *
     * @return Collection<int, Device>
     */
    public function devicesFor(User $user): Collection
    {
        $active = $user->tokens()
            ->where(function (Builder $query): void {
                $query->whereNull('expires_at')
                    ->orWhere('expires_at', '>', CarbonImmutable::now());
            })
            ->pluck('name')
            ->all();

        /** @var Collection<int, Device> $devices */
        $devices = $user->devices()->get();

        return $devices->each(function (Device $device) use ($active): void {
            $device->setAttribute('is_signed_in', in_array($device->device_uid, $active, true));
        });
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
