<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Database\Factories\EntitlementFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * One device's claim on one pack (DLC_SERVER.md §5, §9).
 *
 * Rows here are the single source of truth for "do you own this": there is no
 * implicit ownership anywhere in the code, not even for free packs — a free
 * pack simply grants itself a `source = 'free'` row the first time a token
 * asks for its bytes (see `App\Services\Entitlements`).
 *
 * The owner is always a `Device`. `device_id` is not fillable: who owns what is
 * never something a request body gets to say.
 *
 * `revoked_at` is a tombstone rather than a delete, so a refund is auditable
 * and a re-grant is a deliberate act.
 *
 * @property int $id
 * @property int $device_id
 * @property int $pack_id
 * @property string $source
 * @property string|null $platform
 * @property string|null $platform_txn_id
 * @property CarbonImmutable $granted_at
 * @property CarbonImmutable|null $revoked_at
 * @property CarbonImmutable|null $created_at
 * @property CarbonImmutable|null $updated_at
 * @property-read Device $device
 * @property-read Pack $pack
 */
#[Fillable(['source', 'platform', 'platform_txn_id', 'granted_at', 'revoked_at'])]
class Entitlement extends Model
{
    /** @use HasFactory<EntitlementFactory> */
    use HasFactory;

    public const SOURCE_PURCHASE = 'purchase';

    public const SOURCE_PROMO = 'promo';

    public const SOURCE_FREE = 'free';

    public const SOURCE_GIFT = 'gift';

    public const SOURCE_ADMIN = 'admin';

    public const SOURCES = [
        self::SOURCE_PURCHASE,
        self::SOURCE_PROMO,
        self::SOURCE_FREE,
        self::SOURCE_GIFT,
        self::SOURCE_ADMIN,
    ];

    /**
     * @param  Builder<Entitlement>  $query
     */
    public function scopeLive(Builder $query): void
    {
        $query->whereNull('revoked_at');
    }

    /**
     * @return BelongsTo<Device, $this>
     */
    public function device(): BelongsTo
    {
        return $this->belongsTo(Device::class);
    }

    /**
     * @return BelongsTo<Pack, $this>
     */
    public function pack(): BelongsTo
    {
        return $this->belongsTo(Pack::class);
    }

    public function isLive(): bool
    {
        return $this->revoked_at === null;
    }

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'granted_at' => 'datetime',
            'revoked_at' => 'datetime',
        ];
    }
}
