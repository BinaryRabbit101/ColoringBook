<?php

namespace App\Http\Resources;

use App\Models\Book;
use App\Models\Pack;
use App\Models\PackVersion;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * A pack as the shop sees it (DLC_SERVER.md §11 "Catalog & DLC").
 *
 * `latest_version` is resolved *for the asking client* — a caller on an old
 * build sees the newest release it can actually run, not the newest that
 * exists (§7.3) — so it is passed in rather than read off the model.
 *
 * `owned` means a live `entitlements` row, nothing more. A free pack reads
 * `{"is_free": true, "owned": false}` until the first download claims it (see
 * `App\Services\Entitlements`); the client offers a download for either, and
 * only ever offers a *purchase* for `is_free: false, owned: false`.
 *
 * @mixin Pack
 */
class PackResource extends JsonResource
{
    public function __construct(
        Pack $pack,
        private readonly ?PackVersion $version,
        private readonly bool $owned,
        private readonly bool $detailed = false,
    ) {
        parent::__construct($pack);
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        $payload = [
            'slug' => $this->slug,
            'title' => $this->title,
            'blurb' => $this->blurb,
            // Pack-relative, like every other path in a manifest: entitled
            // clients fetch it through /packs/{slug}/files/{path}.
            'cover' => $this->cover_path,
            // …and the public one, so the shop can render a pack nobody owns
            // yet (WP5). Null when the pack ships no cover at all.
            'cover_url' => $this->cover_path === null
                ? null
                : route('api.v1.packs.cover', ['slug' => $this->slug]),
            'is_free' => $this->is_free,
            'owned' => $this->owned,
            'sort_order' => $this->sort_order,
            'latest_version' => $this->version?->version,
            'min_client_version' => $this->version?->min_client_version,
            'bytes' => $this->version?->archive_bytes,
            'sha256' => $this->version?->archive_sha256,
            'published_at' => $this->version?->published_at?->toIso8601String(),
            'book_count' => $this->books->count(),
            'page_count' => $this->books->sum(fn (Book $book): int => $book->pages->count()),
        ];

        if ($this->detailed) {
            $payload['books'] = $this->books->map(fn (Book $book): array => [
                'book_uid' => $book->book_uid,
                'title' => $book->title,
                'page_count' => $book->pages->count(),
            ])->all();
        }

        return $payload;
    }
}
