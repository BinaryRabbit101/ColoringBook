<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Database\Factories\PackFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Str;

/**
 * A pack: the unit a player acquires and the unit that gets downloaded
 * (DLC_SERVER.md §5, §7).
 *
 * Addressed by `slug` everywhere in §11 — `getRouteKeyName()` says so — and
 * the catalog only ever shows `published` rows. `retired` is a delisting, not
 * a deletion: an owner may still fetch a retired pack's manifest and bytes,
 * because "never delete a pack's files on entitlement loss" (§7.3).
 *
 * @property int $id
 * @property string $ulid
 * @property string $slug
 * @property string $kind
 * @property string $title
 * @property string|null $blurb
 * @property string|null $cover_path
 * @property string $status
 * @property bool $is_free
 * @property string|null $sku_google
 * @property string|null $sku_apple
 * @property string|null $sku_stripe
 * @property int $sort_order
 * @property CarbonImmutable|null $created_at
 * @property CarbonImmutable|null $updated_at
 * @property-read Collection<int, PackVersion> $versions
 * @property-read Collection<int, Book> $books
 * @property-read Collection<int, StickerSet> $stickerSets
 * @property-read Collection<int, Entitlement> $entitlements
 */
#[Fillable(['slug', 'kind', 'title', 'blurb', 'cover_path', 'status', 'is_free', 'sort_order'])]
class Pack extends Model
{
    /** @use HasFactory<PackFactory> */
    use HasFactory;

    /**
     * What the pack CARRIES (BL-37, §7.2). `book` is the default and the only
     * thing that existed before BL-37, so an old manifest with no `kind` and
     * every row written before the column existed both mean "colouring books".
     *
     * The kind decides which payload array the manifest has and which catalog
     * rows a publish rebuilds — and nothing else. Entitlements, downloads,
     * signed URLs and delta updates are identical for both, deliberately.
     */
    public const KIND_BOOK = 'book';

    public const KIND_STICKER_SET = 'sticker_set';

    public const KINDS = [self::KIND_BOOK, self::KIND_STICKER_SET];

    public const STATUS_DRAFT = 'draft';

    public const STATUS_PUBLISHED = 'published';

    public const STATUS_RETIRED = 'retired';

    public const STATUSES = [self::STATUS_DRAFT, self::STATUS_PUBLISHED, self::STATUS_RETIRED];

    /**
     * @var array<string, mixed>
     */
    protected $attributes = [
        'kind' => self::KIND_BOOK,
        'status' => self::STATUS_DRAFT,
        'is_free' => false,
        'sort_order' => 0,
    ];

    /**
     * §11 addresses packs by slug, never by ULID or numeric key.
     */
    public function getRouteKeyName(): string
    {
        return 'slug';
    }

    /**
     * Everything the shop is allowed to list.
     *
     * @param  Builder<Pack>  $query
     */
    public function scopeListable(Builder $query): void
    {
        $query->where('status', self::STATUS_PUBLISHED);
    }

    /**
     * Everything an owner is allowed to *fetch* — which includes retired
     * packs, deliberately (§7.3). Draft packs exist only for the admin.
     *
     * @param  Builder<Pack>  $query
     */
    public function scopeDownloadable(Builder $query): void
    {
        $query->whereIn('status', [self::STATUS_PUBLISHED, self::STATUS_RETIRED]);
    }

    /**
     * @return HasMany<PackVersion, $this>
     */
    public function versions(): HasMany
    {
        return $this->hasMany(PackVersion::class)->orderByDesc('version');
    }

    /**
     * @return HasMany<Book, $this>
     */
    public function books(): HasMany
    {
        return $this->hasMany(Book::class)->orderBy('sort_order')->orderBy('id');
    }

    /**
     * @return HasMany<StickerSet, $this>
     */
    public function stickerSets(): HasMany
    {
        return $this->hasMany(StickerSet::class)->orderBy('sort_order')->orderBy('id');
    }

    public function isStickerSet(): bool
    {
        return $this->kind === self::KIND_STICKER_SET;
    }

    /**
     * @return HasMany<Entitlement, $this>
     */
    public function entitlements(): HasMany
    {
        return $this->hasMany(Entitlement::class);
    }

    /**
     * The newest *published* release, or null while a pack has only drafts.
     */
    public function latestPublishedVersion(): ?PackVersion
    {
        return $this->versions()->published()->first();
    }

    protected static function booted(): void
    {
        static::creating(function (Pack $pack): void {
            if (blank($pack->ulid)) {
                $pack->ulid = (string) Str::ulid();
            }
        });
    }

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'is_free' => 'boolean',
            'sort_order' => 'integer',
        ];
    }
}
