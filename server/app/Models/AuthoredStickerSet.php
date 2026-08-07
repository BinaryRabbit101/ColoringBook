<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Database\Factories\AuthoredStickerSetFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Str;

/**
 * A sticker set being authored in the browser (BL-37).
 *
 * Draft state, and a different thing from `StickerSet` — the same split BL-24
 * drew between `AuthoredBook` and `Book`, for the same reason: the catalog table
 * is rebuilt from the manifest on every publish, so it cannot hold an upload
 * nobody has released yet.
 *
 * It owns a **one-set pack** whose slug is the `set_uid` and whose `kind` is
 * `sticker_set`. Packs stay the delivery and entitlement unit; the operator
 * thinks in sticker sets.
 *
 * @property int $id
 * @property string $ulid
 * @property string $set_uid
 * @property int $pack_id
 * @property string $title
 * @property string|null $blurb
 * @property int $sort_order
 * @property CarbonImmutable|null $created_at
 * @property CarbonImmutable|null $updated_at
 * @property-read Pack $pack
 * @property-read Collection<int, AuthoredSticker> $stickers
 */
#[Fillable(['set_uid', 'title', 'blurb', 'sort_order'])]
class AuthoredStickerSet extends Model
{
    /** @use HasFactory<AuthoredStickerSetFactory> */
    use HasFactory;

    /**
     * @var array<string, mixed>
     */
    protected $attributes = [
        'sort_order' => 100,
    ];

    /**
     * Addressed by its `set_uid`, never by ULID or key — the `AuthoredBook` rule.
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
     * @return HasMany<AuthoredSticker, $this>
     */
    public function stickers(): HasMany
    {
        return $this->hasMany(AuthoredSticker::class)->orderBy('sticker_index');
    }

    /**
     * Every reason this set cannot be published right now, in the operator's
     * language — the list the publish button refuses with.
     *
     * All of them at once, deliberately: a set with three unreadable images
     * should say so once, not three times across three round trips.
     *
     * @param  Collection<int, AuthoredSticker>|null  $stickers
     * @return list<string>
     */
    public function publishBlockers(?Collection $stickers = null): array
    {
        $stickers ??= $this->stickers()->get();

        if ($stickers->isEmpty()) {
            return [__('This sticker set is empty — add a sticker before publishing.')];
        }

        $blockers = [];

        foreach ($stickers as $sticker) {
            foreach ($sticker->publishBlockers() as $blocker) {
                $blockers[] = $blocker;
            }
        }

        return $blockers;
    }

    protected static function booted(): void
    {
        static::creating(function (AuthoredStickerSet $set): void {
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
