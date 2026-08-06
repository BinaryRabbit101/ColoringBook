<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Database\Factories\BookFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Str;

/**
 * A colouring book inside a pack.
 *
 * `book_uid` is authored, not derived (DLC_SERVER.md §6.1). It is the key
 * every save row in WP2/WP4 hangs off, so it is unique across the whole
 * catalog rather than merely within its pack.
 *
 * @property int $id
 * @property string $ulid
 * @property int $pack_id
 * @property string $book_uid
 * @property string $title
 * @property int|null $cover_asset_id
 * @property int $sort_order
 * @property CarbonImmutable|null $created_at
 * @property CarbonImmutable|null $updated_at
 * @property-read Pack $pack
 * @property-read Asset|null $coverAsset
 * @property-read Collection<int, Page> $pages
 */
#[Fillable(['book_uid', 'title', 'cover_asset_id', 'sort_order'])]
class Book extends Model
{
    /** @use HasFactory<BookFactory> */
    use HasFactory;

    /**
     * The public identifier used on every API surface — never the numeric key.
     */
    public function getRouteKeyName(): string
    {
        return 'book_uid';
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
     * @return HasMany<Page, $this>
     */
    public function pages(): HasMany
    {
        return $this->hasMany(Page::class)->orderBy('page_index');
    }

    protected static function booted(): void
    {
        static::creating(function (Book $book): void {
            if (blank($book->ulid)) {
                $book->ulid = (string) Str::ulid();
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
