<?php

namespace App\Services;

use App\Models\Device;
use App\Models\Entitlement;
use App\Models\User;
use Illuminate\Database\Eloquent\Builder;
use InvalidArgumentException;

/**
 * Who a pack belongs to (BL-52, DLC_SERVER.md §4.3).
 *
 * Before BL-52 the answer was always "an account", and every entitlement
 * signature took a `User`. There are now **two identities that can own a
 * pack** — a parent account, or an anonymous device that bought something from
 * the store without anybody typing an email — and this value object is the one
 * place that knows the difference.
 *
 * The invariant it exists to hold is **exactly one owner per row**. SQLite
 * cannot add a CHECK constraint to an existing table, so the database enforces
 * uniqueness (over the `owner_key` generated column) and this class enforces
 * which column gets written. Nothing else in the codebase should ever set
 * `entitlements.user_id` or `entitlements.device_id` by hand.
 *
 * A **linked** device is deliberately not an owner: once a device belongs to an
 * account, that account owns its packs. `fromAuthenticatable()` returns null
 * for one rather than inventing a second inventory nobody can see.
 */
final class EntitlementOwner
{
    /**
     * The column and key are settled here rather than derived on demand, so
     * "exactly one owner" is a property of the object and not something every
     * reader has to re-check.
     */
    private function __construct(
        private readonly ?User $user,
        private readonly ?Device $device,
        private readonly string $column,
        private readonly int $key,
    ) {}

    public static function forUser(User $user): self
    {
        return new self($user, null, 'user_id', $user->id);
    }

    public static function forDevice(Device $device): self
    {
        if (! $device->isAnonymous()) {
            throw new InvalidArgumentException(
                'A linked device does not own packs; its account does.',
            );
        }

        return new self(null, $device, 'device_id', $device->id);
    }

    /**
     * The owner behind a resolved `auth:sanctum` identity, or null when there
     * isn't one — an unauthenticated request, or a token whose device has since
     * been adopted by an account (its tokens are revoked on adoption, so this
     * is belt and braces).
     */
    public static function fromAuthenticatable(mixed $authenticatable): ?self
    {
        if ($authenticatable instanceof User) {
            return self::forUser($authenticatable);
        }

        if ($authenticatable instanceof Device && $authenticatable->isAnonymous()) {
            return self::forDevice($authenticatable);
        }

        return null;
    }

    public function user(): ?User
    {
        return $this->user;
    }

    public function device(): ?Device
    {
        return $this->device;
    }

    public function isAccount(): bool
    {
        return $this->user !== null;
    }

    /**
     * Every entitlement row this owner holds, revoked ones included. Scope with
     * `->live()` for "currently owns".
     *
     * @return Builder<Entitlement>
     */
    public function entitlements(): Builder
    {
        return Entitlement::query()->where($this->column(), $this->key());
    }

    /**
     * Stamp ownership onto a new row. `user_id`/`device_id` are not fillable —
     * who owns what is never something a request body gets to say — so this is
     * the only way a row acquires an owner.
     */
    public function stamp(Entitlement $entitlement): void
    {
        $entitlement->user_id = $this->user?->id;
        $entitlement->device_id = $this->device?->id;
    }

    public function column(): string
    {
        return $this->column;
    }

    public function key(): int
    {
        return $this->key;
    }
}
