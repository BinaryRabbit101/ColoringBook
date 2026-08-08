<?php

namespace App\Concerns;

use App\Models\Asset;
use Illuminate\Support\Facades\Storage;
use Symfony\Component\HttpFoundation\Response;

/**
 * Serving an authored artwork straight out of the content-addressed store, for
 * the admin screens' `<img src>` tags (BL-38).
 *
 * The restructured book and set screens are **thumbnail grids**: a page shows
 * its detail image and its mask, a book shows its cover, a sticker shows its
 * sheet. None of those has a composited preview to render the way a region
 * overlay does — the useful picture IS the file — so all of them are one route
 * that hands the bytes back.
 *
 * It lives in a trait rather than a controller because both doors need it and
 * they differ only in what a *missing* file looks like: a plain 404 page for
 * the browser, the house error shape for the token API. So this returns null
 * and lets the caller say.
 */
trait ServesAuthoringImages
{
    /**
     * The asset's bytes, or null when the row points at a file that is not
     * there — which is a real state: assets are shared by digest and pruning is
     * a separate concern from the rows that name them.
     */
    protected function assetBytes(Asset $asset): ?string
    {
        $disk = Storage::disk((string) config('coloringbook.storage.assets_disk'));

        if (! $disk->exists($asset->storage_path)) {
            return null;
        }

        return (string) $disk->get($asset->storage_path);
    }

    /**
     * The bytes as an image response.
     *
     * `private` caching with the digest as the ETag: content addressing means a
     * replaced image is a different digest, so the URL's *meaning* changes with
     * it and there is nothing to invalidate.
     */
    protected function assetImage(Asset $asset, string $bytes): Response
    {
        return response($bytes, Response::HTTP_OK, [
            'Content-Type' => $asset->mime,
            'Cache-Control' => 'private, max-age=3600',
            'ETag' => '"'.$asset->sha256.'"',
        ]);
    }
}
