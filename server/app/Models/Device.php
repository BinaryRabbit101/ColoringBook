<?php

namespace App\Models;

use Database\Factories\DeviceFactory;
use Illuminate\Auth\Authenticatable as AuthenticatableTrait;
use Illuminate\Contracts\Auth\Authenticatable as AuthenticatableContract;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;
use Laravel\Sanctum\HasApiTokens;
use Laravel\Sanctum\PersonalAccessToken;

/**
 * One install of the game — **and the only client identity there is**.
 *
 * `device_uid` is minted by the client and persisted in `user://`, is unique
 * across the whole table, and is also the **name** of that device's Sanctum
 * token. That naming is the entire revocation story: deleting the tokens named
 * `device_uid` signs out exactly one install.
 *
 * `POST /api/v1/device/register` find-or-creates this row and mints the token
 * **on it** — hence `HasApiTokens` here and `Authenticatable` so the resolved
 * device is handed to `$request->user()` like any other identity. There is no
 * account model behind it: a device owns its own entitlements, and a purchase
 * moves between devices by re-verifying the store receipt, not by signing in.
 *
 * A device has no password and no remember token — nothing ever authenticates
 * one by credentials, only by the token it was issued.
 *
 * @property int $id
 * @property string $ulid
 * @property string $device_uid
 * @property string|null $device_name
 * @property string|null $platform
 * @property Carbon|null $last_seen_at
 * @property Carbon|null $created_at
 * @property Carbon|null $updated_at
 * @property-read Collection<int, Entitlement> $entitlements
 */
#[Fillable(['device_uid', 'device_name', 'platform', 'last_seen_at'])]
class Device extends Model implements AuthenticatableContract
{
    /**
     * @use HasFactory<DeviceFactory>
     * @use HasApiTokens<PersonalAccessToken>
     */
    use AuthenticatableTrait, HasApiTokens, HasFactory;

    /**
     * The public identifier used on every API surface — never the numeric key.
     */
    public function getRouteKeyName(): string
    {
        return 'ulid';
    }

    /**
     * Every pack this device has a claim on, revoked ones included — the server
     * is the entitlement authority, the client never decides (DLC_SERVER.md
     * §9). Scope with `->live()` for "currently owns".
     *
     * @return HasMany<Entitlement, $this>
     */
    public function entitlements(): HasMany
    {
        return $this->hasMany(Entitlement::class);
    }

    protected static function booted(): void
    {
        static::creating(function (Device $device): void {
            if (blank($device->ulid)) {
                $device->ulid = (string) Str::ulid();
            }
        });
    }

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'last_seen_at' => 'datetime',
        ];
    }
}
