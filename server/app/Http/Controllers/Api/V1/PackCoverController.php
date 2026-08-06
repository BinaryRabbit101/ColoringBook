<?php

namespace App\Http\Controllers\Api\V1;

use App\Exceptions\ApiException;
use App\Http\Controllers\Controller;
use App\Models\Asset;
use App\Services\PackCatalog;
use Illuminate\Support\Facades\Storage;
use Symfony\Component\HttpFoundation\Response;

/**
 * `GET /api/v1/packs/{slug}/cover` — the one pack byte a stranger may have.
 *
 * ## Why this route exists
 *
 * WP3 delivers every pack file through `/packs/{slug}/files/{path}`, which
 * requires a token, the `packs:download` ability **and** an entitlement. That
 * is right for page art and wrong for a cover: the shop's whole job is to show
 * a household packs it does *not* own yet, and a cover it cannot render is a
 * grey rectangle with a price on it.
 *
 * Two ways to fix it were on the table. Copying covers onto the `public` disk
 * at publish time would be one fewer PHP request per thumbnail, but it splits
 * a pack's bytes across two storage roots, needs `storage:link` in every
 * deploy, and leaves a published-then-retired pack's cover reachable forever
 * with nothing in the database saying so. Serving it through a route keeps
 * **one** content-addressed store, keeps the decision in code where the
 * catalog's status rules already live, and costs a cached request.
 *
 * So: public, no auth, `listable` packs only (a draft's cover is not a
 * product), immutable caching keyed on the digest.
 */
class PackCoverController extends Controller
{
    public function __construct(private readonly PackCatalog $catalog) {}

    public function __invoke(string $slug): Response
    {
        $pack = $this->catalog->findListable($slug);
        $version = $this->catalog->latestVersion($pack);

        $path = $pack->cover_path;

        if ($version === null || $path === null) {
            throw $this->missing();
        }

        $sha = $version->files()[$path]['sha256'] ?? null;

        if (! is_string($sha) || $sha === '') {
            throw $this->missing();
        }

        $disk = Storage::disk((string) config('coloringbook.storage.assets_disk'));
        $storagePath = Asset::pathFor($sha);

        if (! $disk->exists($storagePath)) {
            throw $this->missing();
        }

        return response((string) $disk->get($storagePath), Response::HTTP_OK, [
            'Content-Type' => $this->mimeFor($path),
            // Content-addressed bytes cannot change under a digest, and the
            // digest changes with every release — so this is safe to cache
            // hard and shared caches are welcome to it.
            'Cache-Control' => 'public, max-age=86400',
            'ETag' => '"'.$sha.'"',
        ]);
    }

    private function mimeFor(string $path): string
    {
        return match (strtolower((string) pathinfo($path, PATHINFO_EXTENSION))) {
            'png' => 'image/png',
            'jpg', 'jpeg' => 'image/jpeg',
            'webp' => 'image/webp',
            default => 'application/octet-stream',
        };
    }

    /**
     * A pack with no cover is not an error the shop should retry — it renders
     * its placeholder and moves on.
     */
    private function missing(): ApiException
    {
        return new ApiException(
            'FILE_NOT_FOUND',
            __('That pack has no cover image.'),
            Response::HTTP_NOT_FOUND,
        );
    }
}
