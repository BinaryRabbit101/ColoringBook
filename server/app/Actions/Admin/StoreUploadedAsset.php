<?php

namespace App\Actions\Admin;

use App\Models\Asset;
use Illuminate\Http\UploadedFile;

/**
 * `POST /admin/assets` — one artifact, stored under its own digest
 * (DLC_SERVER.md §5, §11 "Admin").
 *
 * Content addressing makes the endpoint **idempotent for free**: the same
 * bytes uploaded twice land on the same path and resolve to the same row, so
 * a `pack build` script that dies halfway and reruns costs one HEAD-equivalent
 * per file rather than a duplicate tree. That is the whole reason the upload
 * step exists separately from the version step — a 40 MB pack whose fifth page
 * changed uploads one page.
 *
 * The storing itself lives in `StoreAssetFile`, which BL-24's mapping job also
 * uses for artifacts that never came through HTTP at all. All this adds is the
 * one thing an upload knows and a file on disk does not: the *client's*
 * filename, which is where the MIME type comes from.
 */
class StoreUploadedAsset
{
    public function __construct(private readonly StoreAssetFile $store) {}

    public function handle(UploadedFile $file, string $kind): Asset
    {
        return $this->store->handle(
            (string) $file->getRealPath(),
            $kind,
            $file->getClientOriginalExtension(),
        );
    }
}
