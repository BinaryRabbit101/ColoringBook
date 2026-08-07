<?php

namespace App\Actions\Admin;

use App\Models\Asset;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/**
 * A file on disk → a content-addressed `assets` row (DLC_SERVER.md §5).
 *
 * This is the shared half of asset storage. `StoreUploadedAsset` wraps it for
 * `POST /admin/assets`, and the BL-24 mapping job uses it directly for the
 * artifacts headless Godot just wrote into a scratch directory — those never
 * arrive as an HTTP upload, and routing them through a synthetic `UploadedFile`
 * to reach the same six lines would be theatre.
 *
 * Identity is `(sha256, kind)`, never `sha256` alone: one blob legitimately
 * wears two roles (a page's display art doubling as its book's cover), and the
 * two rows differ only in `kind`. Re-storing identical bytes is therefore free
 * and idempotent, which is what makes re-running a mapping job cheap.
 */
class StoreAssetFile
{
    /**
     * @param  string  $absolutePath  The bytes to store.
     * @param  string  $kind  One of `Asset::KINDS`.
     * @param  string|null  $extension  Names the MIME type. Defaults to the
     *                                  path's own extension; pass it
     *                                  explicitly when the bytes came from an
     *                                  upload whose real path has none.
     */
    public function handle(string $absolutePath, string $kind, ?string $extension = null): Asset
    {
        $sha256 = (string) hash_file('sha256', $absolutePath);
        $storagePath = Asset::pathFor($sha256);
        $disk = Storage::disk((string) config('coloringbook.storage.assets_disk'));

        // Content addressing: identical bytes are already there, by definition.
        if (! $disk->exists($storagePath)) {
            $handle = fopen($absolutePath, 'rb');

            if ($handle !== false) {
                $disk->put($storagePath, $handle);
                fclose($handle);
            }
        }

        $size = @getimagesize($absolutePath);
        [$width, $height] = $size === false ? [null, null] : [(int) $size[0], (int) $size[1]];

        /** @var Asset $asset */
        $asset = Asset::query()->firstOrCreate(
            ['sha256' => $sha256, 'kind' => $kind],
            [
                'storage_path' => $storagePath,
                'bytes' => (int) filesize($absolutePath),
                'mime' => self::mimeFor($extension ?? pathinfo($absolutePath, PATHINFO_EXTENSION)),
                'width' => $width,
                'height' => $height,
            ],
        );

        return $asset;
    }

    /**
     * A fixed table keyed on the file's extension, never a sniff: these bytes
     * are content-addressed and validated on the way in, and guessing a type
     * for something we will later serve to a browser is how a PNG becomes an
     * HTML page.
     */
    public static function mimeFor(string $extension): string
    {
        return match (Str::lower($extension)) {
            'png' => 'image/png',
            'json' => 'application/json',
            'jpg', 'jpeg' => 'image/jpeg',
            'webp' => 'image/webp',
            'zip' => 'application/zip',
            default => 'application/octet-stream',
        };
    }
}
