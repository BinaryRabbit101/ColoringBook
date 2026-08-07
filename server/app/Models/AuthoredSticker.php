<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Database\Factories\AuthoredStickerFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Str;

/**
 * One sticker in the authoring workspace (BL-37).
 *
 * `AuthoredPage` has two halves — what was uploaded, and what the mapping job
 * made of it. This has only the first: a sticker has no regions, so there is no
 * pipeline, no queue and no `mapping_status`. `StickerValidation` reads the
 * image the moment it is uploaded and stores the verdict, and that verdict is
 * the whole publish gate.
 *
 * @property int $id
 * @property string $ulid
 * @property int $authored_sticker_set_id
 * @property int $sticker_index
 * @property string $sticker_id
 * @property string|null $title
 * @property int $image_asset_id
 * @property int|null $image_w
 * @property int|null $image_h
 * @property list<string>|null $validation_errors
 * @property list<string>|null $validation_warnings
 * @property CarbonImmutable|null $created_at
 * @property CarbonImmutable|null $updated_at
 * @property-read AuthoredStickerSet $set
 * @property-read Asset $imageAsset
 */
#[Fillable(['sticker_index', 'sticker_id', 'title', 'image_asset_id'])]
class AuthoredSticker extends Model
{
    /** @use HasFactory<AuthoredStickerFactory> */
    use HasFactory;

    public function getRouteKeyName(): string
    {
        return 'ulid';
    }

    /**
     * @return BelongsTo<AuthoredStickerSet, $this>
     */
    public function set(): BelongsTo
    {
        return $this->belongsTo(AuthoredStickerSet::class, 'authored_sticker_set_id');
    }

    /**
     * @return BelongsTo<Asset, $this>
     */
    public function imageAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'image_asset_id');
    }

    /**
     * The pack-relative file name this sticker ships under. Named after its
     * stable `sticker_id` rather than its index, because the index moves when
     * the operator reorders the set and a delta update would then re-download
     * every file after the one that moved (§7.4, BL-26).
     */
    public function fileName(): string
    {
        return $this->sticker_id.'.png';
    }

    public function isPublishable(): bool
    {
        return ($this->validation_errors ?? []) === [];
    }

    /**
     * Why this sticker is not publishable, in the operator's language.
     *
     * @return list<string>
     */
    public function publishBlockers(): array
    {
        return array_map(
            fn (string $error): string => sprintf('%s: %s', $this->label(), $error),
            $this->validation_errors ?? [],
        );
    }

    /**
     * How this sticker is named in a message: its title when it has one, its
     * id when it does not.
     */
    public function label(): string
    {
        return $this->title !== null && trim($this->title) !== ''
            ? sprintf('%s (%s)', trim($this->title), $this->sticker_id)
            : $this->sticker_id;
    }

    protected static function booted(): void
    {
        static::creating(function (AuthoredSticker $sticker): void {
            if (blank($sticker->ulid)) {
                $sticker->ulid = (string) Str::ulid();
            }
        });
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
            'validation_errors' => 'array',
            'validation_warnings' => 'array',
        ];
    }
}
