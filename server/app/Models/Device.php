<?php

namespace App\Models;

use Database\Factories\DeviceFactory;
use Illuminate\Auth\Authenticatable as AuthenticatableTrait;
use Illuminate\Contracts\Auth\Authenticatable as AuthenticatableContract;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;
use Laravel\Sanctum\HasApiTokens;
use Laravel\Sanctum\PersonalAccessToken;

/**
 * One install of the game.
 *
 * `device_uid` is minted by the client and persisted in `user://`; for a
 * *linked* device it is also the **name** of that device's Sanctum token, which
 * is the whole revocation story: deleting the tokens named `device_uid` signs
 * out exactly one device and leaves the rest of the household alone
 * (DLC_SERVER.md §4.2).
 *
 * ## Two kinds of row (BL-52, §4.3)
 *
 * - **Linked** (`user_id` set) — the original: an install that has signed in.
 * - **Anonymous** (`user_id` NULL) — an install that has never signed in but
 *   has bought something. `POST /device/register` creates it, and the token it
 *   is issued is minted **on this model** (hence `HasApiTokens` here as well as
 *   on `User`), carrying `entitlements:read` + `packs:download` and never
 *   `save:sync`. An anonymous device can own packs; it can never upload a
 *   child's artwork.
 *
 * Uniqueness of `device_uid` is `UNIQUE(coalesce(user_id, 0), device_uid)`, so
 * an account may hold one row per uid and there is at most one anonymous row
 * per uid. The two never mix: registering only ever scopes to the anonymous
 * row, so knowing a uid earns an attacker a fresh empty identity rather than
 * somebody's account.
 *
 * @property int $id
 * @property string $ulid
 * @property int|null $user_id
 * @property string $device_uid
 * @property string|null $device_name
 * @property string|null $platform
 * @property Carbon|null $last_seen_at
 * @property Carbon|null $created_at
 * @property Carbon|null $updated_at
 * @property-read User|null $user
 * @property-read Collection<int, Entitlement> $entitlements
 * @property-read bool $is_signed_in  set by DeviceTokens::devicesFor(); not a column
 */
#[Fillable(['device_uid', 'device_name', 'platform', 'last_seen_at'])]
class Device extends Model implements AuthenticatableContract
{
    /**
     * `HasApiTokens` is what lets Sanctum authenticate a bearer token whose
     * tokenable is a device rather than a user; `Authenticatable` is what lets
     * the resolved device be handed to `$request->user()` like any other
     * identity. It has no password and no remember token — nothing ever
     * authenticates a device by credentials, only by the token it was issued.
     *
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
     * @return BelongsTo<User, $this>
     */
    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    /**
     * Packs this *anonymous* device owns in its own right (BL-52). A linked
     * device never has rows here — its packs belong to its account, which is
     * what adoption on sign-in makes true.
     *
     * @return HasMany<Entitlement, $this>
     */
    public function entitlements(): HasMany
    {
        return $this->hasMany(Entitlement::class);
    }

    public function isAnonymous(): bool
    {
        return $this->user_id === null;
    }

    /**
     * The anonymous row for a uid, or null. Deliberately the only lookup the
     * registration path uses: a uid that belongs to an account is invisible
     * here (§4.3).
     *
     * @param  Builder<Device>  $query
     */
    public function scopeAnonymous(Builder $query): void
    {
        $query->whereNull('user_id');
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
