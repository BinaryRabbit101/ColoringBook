<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Database\Factories\StickerSetFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Str;

/**
 * A sticker set inside a pack (BL-37) — `Book`'s sibling, and the same kind of
 * row: the catalog's record of what the newest release contains, rebuilt from
 * the manifest on every publish.
 *
 * `set_uid` is authored, not derived, and unique across the whole catalog for
 * the reason `book_uid` is (§6.1): a saved sticker placement names it, so two
 * packs sharing one uid would silently merge two different sets on every device
 * that has both.
 *
 * @property int $id
 * @property string $ulid
 * @property int $pack_id
 * @property string $set_uid
 * @property string $title
 * @property int|null $cover_asset_id
 * @property int $sort_order
 * @property CarbonImmutable|null $created_at
 * @property CarbonImmutable|null $updated_at
 * @property-read Pack $pack
 * @property-read Asset|null $coverAsset
 * @property-read Collection<int, Sticker> $stickers
 */
#[Fillable(['set_uid', 'title', 'cover_asset_id', 'sort_order'])]
class StickerSet extends Model
{
    /** @use HasFactory<StickerSetFactory> */
    use HasFactory;

    /**
     * The public identifier used on every API surface — never the numeric key.
     */
    public function getRouteKeyName(): string
    {
        return 'set_uid';
    }

    /**
     * @return BelongsTo<Pack, $this>
     */
    public function pack(): BelongsTo
    {
        return $this->belongsTo(Pack::class);
    }

    /**
     * @return BelongsTo<Asset, $this>
     */
    public function coverAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'cover_asset_id');
    }

    /**
     * @return HasMany<Sticker, $this>
     */
    public function stickers(): HasMany
    {
        return $this->hasMany(Sticker::class)->orderBy('sticker_index');
    }

    protected static function booted(): void
    {
        static::creating(function (StickerSet $set): void {
            if (blank($set->ulid)) {
                $set->ulid = (string) Str::ulid();
            }
        });
    }

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'sort_order' => 'integer',
        ];
    }
}
