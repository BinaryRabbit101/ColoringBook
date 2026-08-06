<?php

namespace App\Actions\Admin;

use App\Models\Asset;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

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
 * The `(sha256, kind)` pair is the identity, not `sha256` alone: one blob
 * legitimately wears two roles (a page's display art doubling as its book's
 * cover), and the two rows differ only in `kind`.
 */
class StoreUploadedAsset
{
    public function handle(UploadedFile $file, string $kind): Asset
    {
        $sha256 = (string) hash_file('sha256', $file->getRealPath());
        $storagePath = Asset::pathFor($sha256);
        $disk = Storage::disk((string) config('coloringbook.storage.assets_disk'));

        if (! $disk->exists($storagePath)) {
            $handle = fopen($file->getRealPath(), 'rb');

            if ($handle !== false) {
                $disk->put($storagePath, $handle);
                fclose($handle);
            }
        }

        [$width, $height] = $this->dimensions($file);

        /** @var Asset $asset */
        $asset = Asset::query()->firstOrCreate(
            ['sha256' => $sha256, 'kind' => $kind],
            [
                'storage_path' => $storagePath,
                'bytes' => (int) $file->getSize(),
                'mime' => $this->mimeFor($file),
                'width' => $width,
                'height' => $height,
            ],
        );

        return $asset;
    }

    /**
     * @return array{0: int|null, 1: int|null}
     */
    private function dimensions(UploadedFile $file): array
    {
        $size = @getimagesize($file->getRealPath());

        return $size === false ? [null, null] : [(int) $size[0], (int) $size[1]];
    }

    /**
     * A fixed table keyed on the *client's* filename extension, exactly like
     * the publisher's: these bytes are content-addressed and validated on the
     * way in, and sniffing a type out of something we will later serve to a
     * browser is how a PNG becomes an HTML page.
     */
    private function mimeFor(UploadedFile $file): string
    {
        return match (Str::lower($file->getClientOriginalExtension())) {
            'png' => 'image/png',
            'json' => 'application/json',
            'jpg', 'jpeg' => 'image/jpeg',
            'webp' => 'image/webp',
            'zip' => 'application/zip',
            default => 'application/octet-stream',
        };
    }
}
