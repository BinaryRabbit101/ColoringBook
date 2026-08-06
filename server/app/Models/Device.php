<?php

namespace App\Models;

use Database\Factories\DeviceFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;

/**
 * One install of the game that has signed in at least once.
 *
 * `device_uid` is minted by the client and persisted in `user://`; it is also
 * the *name* of that device's Sanctum token, which is the whole revocation
 * story: deleting the tokens named `device_uid` signs out exactly one device
 * and leaves the rest of the household alone (DLC_SERVER.md §4.2).
 *
 * @property int $id
 * @property string $ulid
 * @property int $user_id
 * @property string $device_uid
 * @property string|null $device_name
 * @property string|null $platform
 * @property Carbon|null $last_seen_at
 * @property Carbon|null $created_at
 * @property Carbon|null $updated_at
 * @property-read User $user
 * @property-read bool $is_signed_in  set by DeviceTokens::devicesFor(); not a column
 */
#[Fillable(['device_uid', 'device_name', 'platform', 'last_seen_at'])]
class Device extends Model
{
    /** @use HasFactory<DeviceFactory> */
    use HasFactory;

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
