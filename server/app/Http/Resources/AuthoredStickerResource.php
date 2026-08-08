<?php

namespace App\Http\Resources;

use App\Models\Asset;
use App\Models\AuthoredSticker;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * One authored sticker, as the set editor sees it (BL-37).
 *
 * Much shorter than `AuthoredPageResource` and that is the point: there is no
 * mapping status, no tuning and no derived artifacts, because a sticker has no
 * regions. What is left is the upload, its size, and what `StickerValidation`
 * made of it — carried verbatim, because the editor's job is to make a failure
 * legible rather than hide it.
 *
 * @mixin AuthoredSticker
 */
class AuthoredStickerResource extends JsonResource
{
    /**
     * @param  string  $routePrefix  `admin.` for the browser, `api.v1.admin.`
     *                               for the token door — the image is a PNG
     *                               route and an `<img src>` cannot carry a
     *                               bearer token.
     */
    public function __construct(AuthoredSticker $sticker, private readonly string $routePrefix = 'admin.')
    {
        parent::__construct($sticker);
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        return [
            'ulid' => $this->ulid,
            'sticker_index' => $this->sticker_index,
            'sticker_id' => $this->sticker_id,
            'title' => $this->title,
            'file_name' => $this->fileName(),

            'image' => $this->asset($this->imageAsset),
            'image_size' => $this->image_w !== null && $this->image_h !== null
                ? [$this->image_w, $this->image_h]
                : null,

            // BL-38: the sprite-sheet grid, verbatim as the manifest carries
            // it, or null for a still sticker. The admin UI animates the
            // preview off these four numbers, which means what the operator
            // watches is what the game will play.
            'anim' => $this->anim,

            'validation_errors' => $this->validation_errors ?? [],
            'validation_warnings' => $this->validation_warnings ?? [],
            'publishable' => $this->isPublishable(),
            'blockers' => $this->publishBlockers(),

            'image_url' => route($this->routePrefix.'sticker-sets.stickers.image', [
                'set' => $this->set->set_uid,
                'index' => $this->sticker_index,
            ]),
        ];
    }

    /**
     * @return array{ulid: string, sha256: string, bytes: int, width: int|null, height: int|null, kind: string}|null
     */
    private function asset(?Asset $asset): ?array
    {
        return $asset === null ? null : [
            'ulid' => $asset->ulid,
            'sha256' => $asset->sha256,
            'bytes' => $asset->bytes,
            'width' => $asset->width,
            'height' => $asset->height,
            'kind' => $asset->kind,
        ];
    }
}
