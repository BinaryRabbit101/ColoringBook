<?php

namespace App\Http\Resources;

use App\Models\Asset;
use App\Models\AuthoredPage;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * One authored page, as the page editor and `GET .../pages/{index}/status` see
 * it (BL-24, §11's web-authoring table).
 *
 * It carries the *whole* verdict — mapping state, §10.1 errors and warnings,
 * and whether the page can be published — because the editor's job is to make
 * a failure legible rather than to hide it. A giant region says "a line has a
 * gap"; that sentence comes out of `PackValidation` and travels all the way to
 * the screen unedited.
 *
 * @mixin AuthoredPage
 */
class AuthoredPageResource extends JsonResource
{
    /**
     * @param  string  $routePrefix  `admin.` for the browser, `api.v1.admin.`
     *                               for the token door — the preview is a PNG
     *                               route and an `<img src>` cannot carry a
     *                               bearer token, so the two doors name
     *                               different routes for the same picture.
     */
    public function __construct(AuthoredPage $page, private readonly string $routePrefix = 'admin.')
    {
        parent::__construct($page);
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        $bookUid = $this->book->book_uid;

        return [
            'ulid' => $this->ulid,
            'page_index' => $this->page_index,
            'title' => $this->title,
            'file_stem' => $this->fileStem(),

            'display' => $this->asset($this->displayAsset),
            'mask' => $this->asset($this->maskAsset),
            'has_mask' => $this->hasMask(),
            // BL-12: what actually ships is the pipeline's display-resolution
            // resample, not the artist's original.
            'shipped_mask' => $this->asset($this->maskArtifactAsset),

            'idmap' => $this->asset($this->idmapAsset),
            'regions' => $this->asset($this->regionsAsset),
            'image_size' => $this->image_w !== null && $this->image_h !== null
                ? [$this->image_w, $this->image_h]
                : null,
            'region_count' => $this->region_count,

            'mapping_status' => $this->mapping_status,
            'mapping_error' => $this->mapping_error,
            'mapping_log' => $this->mapping_log,
            'mapped_at' => $this->mapped_at?->toIso8601String(),

            'validation_errors' => $this->validation_errors ?? [],
            'validation_warnings' => $this->validation_warnings ?? [],
            'publishable' => $this->isPublishable(),
            'blockers' => $this->publishBlockers(),

            'tuning' => $this->tuning,
            'effective_tuning' => $this->effectiveTuning(),

            'preview_url' => $this->isMapped()
                ? route($this->routePrefix.'books.pages.preview', ['book' => $bookUid, 'index' => $this->page_index])
                : null,

            // BL-38: the two thumbnails the restructured book screen shows.
            // The overlay above answers "did the mapping work"; these answer
            // "which drawing is this", which is what the operator is scanning a
            // page list for. `mask_url` is null on a page with no mask — the
            // normal case — so the screen renders an empty add-a-mask slot
            // rather than a broken image.
            // Never null: a page cannot exist without its detail image.
            'display_url' => route($this->routePrefix.'books.pages.display', [
                'book' => $bookUid,
                'index' => $this->page_index,
            ]),
            'mask_url' => $this->hasMask()
                ? route($this->routePrefix.'books.pages.mask', ['book' => $bookUid, 'index' => $this->page_index])
                : null,
            'status_url' => route($this->routePrefix.'books.pages.status', [
                'book' => $bookUid,
                'index' => $this->page_index,
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
