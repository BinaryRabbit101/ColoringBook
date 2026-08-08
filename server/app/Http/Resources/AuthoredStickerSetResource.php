<?php

namespace App\Http\Resources;

use App\Models\AuthoredSticker;
use App\Models\AuthoredStickerSet;
use App\Models\PackVersion;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * A sticker set in the authoring workspace (BL-37) — `AuthoredBookResource`'s
 * sibling, and the same two numbers on the surface: how much is still not
 * publishable, and what the pack has actually released.
 *
 * The second is read off the *pack*, not off this table, because the workspace
 * is draft state and the catalog is what players have. Keeping them visibly
 * separate is the point of the whole two-table design.
 *
 * @mixin AuthoredStickerSet
 */
class AuthoredStickerSetResource extends JsonResource
{
    public function __construct(
        AuthoredStickerSet $set,
        private readonly bool $withStickers = false,
        private readonly string $routePrefix = 'admin.',
    ) {
        parent::__construct($set);
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        /** @var Collection<int, AuthoredSticker> $stickers */
        $stickers = $this->relationLoaded('stickers') ? $this->stickers : $this->stickers()->get();

        $pack = $this->pack;
        $published = null;
        $publishedAt = null;

        foreach ($pack->versions as $version) {
            /** @var PackVersion $version */
            if ($version->published_at !== null && ($published === null || $version->version > $published)) {
                $published = $version->version;
                $publishedAt = $version->published_at;
            }
        }

        $blockers = $this->publishBlockers($stickers);
        $modifiedAt = $this->lastModifiedAt($stickers);

        $payload = [
            'set_uid' => $this->set_uid,
            'title' => $this->title,
            'blurb' => $this->blurb,
            'sort_order' => $this->sort_order,
            'pack_slug' => $pack->slug,
            'pack_kind' => $pack->kind,
            'pack_status' => $pack->status,
            'is_free' => $pack->is_free,
            'sticker_count' => $stickers->count(),
            'unpublishable_sticker_count' => $stickers->filter(
                fn (AuthoredSticker $sticker): bool => ! $sticker->isPublishable(),
            )->count(),
            'latest_published_version' => $published,

            // BL-38, the same two questions the book list asks: when did this
            // last ship, and is there anything here that has not.
            'last_published_at' => $publishedAt?->toIso8601String(),
            'last_modified_at' => $modifiedAt?->toIso8601String(),
            'modified_since_publish' => $publishedAt === null
                || ($modifiedAt !== null && $modifiedAt->greaterThan($publishedAt)),

            'animated_sticker_count' => $stickers->filter(
                fn (AuthoredSticker $sticker): bool => $sticker->isAnimated(),
            )->count(),

            'publishable' => $blockers === [],
            'blockers' => $blockers,
            'created_at' => $this->created_at?->toIso8601String(),
            'updated_at' => $this->updated_at?->toIso8601String(),
        ];

        if ($this->withStickers) {
            $payload['stickers'] = $stickers
                ->map(fn (AuthoredSticker $sticker): array => (new AuthoredStickerResource($sticker, $this->routePrefix))
                    ->toArray($request))
                ->all();
        }

        return $payload;
    }
}
