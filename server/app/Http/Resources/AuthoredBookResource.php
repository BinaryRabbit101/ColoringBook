<?php

namespace App\Http\Resources;

use App\Models\Asset;
use App\Models\AuthoredBook;
use App\Models\AuthoredPage;
use App\Models\PackVersion;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * A book in the authoring workspace (BL-24, §11's web-authoring table).
 *
 * The two numbers that matter to the operator are on the surface: how many
 * pages are still not publishable, and what the pack has actually released. The
 * second is read off the *pack*, not off this table, because the workspace is
 * draft state and the catalog is what players have — keeping them visibly
 * separate is the point of the whole two-table design.
 *
 * @mixin AuthoredBook
 */
class AuthoredBookResource extends JsonResource
{
    public function __construct(
        AuthoredBook $book,
        private readonly bool $withPages = false,
        private readonly string $routePrefix = 'admin.',
    ) {
        parent::__construct($book);
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        /** @var Collection<int, AuthoredPage> $pages */
        $pages = $this->relationLoaded('pages') ? $this->pages : $this->pages()->get();

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

        $blockers = $this->publishBlockers($pages);
        $modifiedAt = $this->lastModifiedAt($pages);

        $payload = [
            'book_uid' => $this->book_uid,
            'title' => $this->title,
            'blurb' => $this->blurb,
            'pack_slug' => $pack->slug,
            'pack_status' => $pack->status,
            'is_free' => $pack->is_free,
            'page_count' => $pages->count(),
            'unpublishable_page_count' => $pages->filter(
                fn (AuthoredPage $page): bool => ! $page->isPublishable(),
            )->count(),
            'latest_published_version' => $published,

            // BL-38: the two questions the book list actually asks — when did
            // this last ship, and is there anything in the workspace that has
            // not. `last_modified_at` is the newest timestamp anywhere in the
            // book, because adding or replacing a page never writes to the book
            // row and both change what a publish would ship.
            'last_published_at' => $publishedAt?->toIso8601String(),
            'last_modified_at' => $modifiedAt?->toIso8601String(),
            'modified_since_publish' => $publishedAt === null
                || ($modifiedAt !== null && $modifiedAt->greaterThan($publishedAt)),

            // BL-38's optional artist cover. Absent is normal and means the
            // publisher falls back to page one's display art.
            'cover' => $this->asset($this->coverAsset),
            'has_cover' => $this->cover_asset_id !== null,
            'cover_url' => $this->cover_asset_id === null
                ? null
                : route($this->routePrefix.'books.cover', ['book' => $this->book_uid]),

            'publishable' => $blockers === [],
            'blockers' => $blockers,
            'created_at' => $this->created_at?->toIso8601String(),
            'updated_at' => $this->updated_at?->toIso8601String(),
        ];

        if ($this->withPages) {
            $payload['pages'] = $pages
                ->map(fn (AuthoredPage $page): array => (new AuthoredPageResource($page, $this->routePrefix))->toArray($request))
                ->all();
        }

        return $payload;
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
