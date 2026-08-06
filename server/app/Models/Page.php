<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Database\Factories\PageFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * One page: the display art, the ID map, the regions JSON — and, optionally,
 * the outline mask that generated them.
 *
 * `mask_asset_id` being null is a normal, supported state, not missing data:
 * a page with no mask was mapped straight from its display image (BL-9 /
 * BL-12, DLC_SERVER.md §7.2). The mask never travels in a pack either way.
 *
 * @property int $id
 * @property int $book_id
 * @property int $page_index
 * @property string|null $title
 * @property int $display_asset_id
 * @property int|null $mask_asset_id
 * @property int $idmap_asset_id
 * @property int $regions_asset_id
 * @property int $image_w
 * @property int $image_h
 * @property int $region_count
 * @property CarbonImmutable|null $created_at
 * @property CarbonImmutable|null $updated_at
 * @property-read Book $book
 * @property-read Asset $displayAsset
 * @property-read Asset|null $maskAsset
 * @property-read Asset $idmapAsset
 * @property-read Asset $regionsAsset
 */
#[Fillable([
    'page_index',
    'title',
    'display_asset_id',
    'mask_asset_id',
    'idmap_asset_id',
    'regions_asset_id',
    'image_w',
    'image_h',
    'region_count',
])]
class Page extends Model
{
    /** @use HasFactory<PageFactory> */
    use HasFactory;

    /**
     * @return BelongsTo<Book, $this>
     */
    public function book(): BelongsTo
    {
        return $this->belongsTo(Book::class);
    }

    /**
     * @return BelongsTo<Asset, $this>
     */
    public function displayAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'display_asset_id');
    }

    /**
     * @return BelongsTo<Asset, $this>
     */
    public function maskAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'mask_asset_id');
    }

    /**
     * @return BelongsTo<Asset, $this>
     */
    public function idmapAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'idmap_asset_id');
    }

    /**
     * @return BelongsTo<Asset, $this>
     */
    public function regionsAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'regions_asset_id');
    }

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'page_index' => 'integer',
            'image_w' => 'integer',
            'image_h' => 'integer',
            'region_count' => 'integer',
        ];
    }
}
