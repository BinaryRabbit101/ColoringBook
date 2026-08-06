<?php

namespace App\Http\Resources;

use App\Models\PackVersion;
use App\Services\PackManifest;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * One release, as the admin sees it — which is more than the shop does: a
 * draft has no `published_at` and is invisible everywhere else in the
 * application (§7.3).
 *
 * Counts come from the stored manifest rather than from `books`/`pages`,
 * because those rows always describe the *newest* release and would report
 * v3's shape while looking at v1.
 *
 * @mixin PackVersion
 */
class AdminPackVersionResource extends JsonResource
{
    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        $manifest = new PackManifest($this->manifest);
        $books = $manifest->books();

        return [
            'version' => $this->version,
            'status' => $this->published_at === null ? 'draft' : 'published',
            'published_at' => $this->published_at?->toIso8601String(),
            'created_at' => $this->created_at?->toIso8601String(),
            'min_client_version' => $this->min_client_version,
            'bytes' => $this->archive_bytes,
            'sha256' => $this->archive_sha256,
            'book_count' => count($books),
            'page_count' => array_sum(array_map(
                static fn (array $book): int => count(PackManifest::pagesOf($book)),
                $books,
            )),
        ];
    }
}
