<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Database\Factories\StickerFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * One sticker of a published set (BL-37): a stable id and one image.
 *
 * `sticker_id` is unique within its set, not globally — two sets may both offer
 * a `star`, and a saved placement names the pair `(set_uid, sticker_id)`.
 *
 * There is deliberately no ID map, no regions JSON and no `region_count` here.
 * A sticker has no regions, so §10.1's mapping pipeline does not apply to it and
 * the publish gate is image validation only.
 *
 * @property int $id
 * @property int $sticker_set_id
 * @property int $sticker_index
 * @property string $sticker_id
 * @property string|null $title
 * @property int $image_asset_id
 * @property int|null $image_w
 * @property int|null $image_h
 * @property array{hframes: int, vframes: int, frames: int, fps: float}|null $anim
 * @property CarbonImmutable|null $created_at
 * @property CarbonImmutable|null $updated_at
 * @property-read StickerSet $set
 * @property-read Asset $imageAsset
 */
#[Fillable(['sticker_index', 'sticker_id', 'title', 'image_asset_id', 'image_w', 'image_h', 'anim'])]
class Sticker extends Model
{
    /** @use HasFactory<StickerFactory> */
    use HasFactory;

    /**
     * @return BelongsTo<StickerSet, $this>
     */
    public function set(): BelongsTo
    {
        return $this->belongsTo(StickerSet::class, 'sticker_set_id');
    }

    /**
     * @return BelongsTo<Asset, $this>
     */
    public function imageAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'image_asset_id');
    }

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'sticker_index' => 'integer',
            'image_w' => 'integer',
            'image_h' => 'integer',
            // BL-38: null for a static sticker, which is every sticker
            // published before it and the shape the game still reads.
            'anim' => 'array',
        ];
    }
}
