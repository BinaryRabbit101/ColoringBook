<?php

namespace App\Services\Authoring;

use App\Exceptions\ApiException;
use App\Models\AuthoredPage;
use App\Services\PackPreview;
use Illuminate\Support\Facades\Storage;
use Symfony\Component\HttpFoundation\Response;

/**
 * The §10.1 region-overlay preview for a page that has not been published yet
 * (BL-24, §10.3).
 *
 * The reviewer's question about a freshly mapped page is the same one it always
 * was — *did this map to the shapes I drew* — and the only honest answer is a
 * picture. `PackPreview` already composites one; all this adds is where the two
 * images come from (content-addressed assets, not a release's `files/` tree)
 * and where the result is cached.
 *
 * **The cache key is the two digests.** A page whose art or mapping changed
 * gets a different key by construction, so there is no invalidation step to
 * forget — and re-mapping a page back to identical artifacts is a cache hit,
 * not a stale entry.
 */
class AuthoredPagePreview
{
    public function __construct(private readonly PackPreview $preview) {}

    public function render(AuthoredPage $page): string
    {
        $display = $page->displayAsset;
        $idmap = $page->idmapAsset;

        if ($idmap === null) {
            throw new ApiException(
                'PAGE_NOT_MAPPED',
                __('That page has not been mapped yet, so there is nothing to overlay.'),
                Response::HTTP_NOT_FOUND,
            );
        }

        $packs = Storage::disk((string) config('coloringbook.storage.packs_disk'));
        $cached = sprintf('authoring/previews/%s-%s.png', substr($display->sha256, 0, 16), substr($idmap->sha256, 0, 16));

        if ($packs->exists($cached)) {
            return (string) $packs->get($cached);
        }

        $assets = Storage::disk((string) config('coloringbook.storage.assets_disk'));
        $displayBytes = $assets->exists($display->storage_path) ? $assets->get($display->storage_path) : null;
        $idmapBytes = $assets->exists($idmap->storage_path) ? $assets->get($idmap->storage_path) : null;

        if (! is_string($displayBytes) || ! is_string($idmapBytes)) {
            throw new ApiException(
                'FILE_NOT_FOUND',
                __('That page artwork is no longer on disk.'),
                Response::HTTP_NOT_FOUND,
            );
        }

        $png = $this->preview->renderPair($displayBytes, $idmapBytes);
        $packs->put($cached, $png);

        return $png;
    }
}
