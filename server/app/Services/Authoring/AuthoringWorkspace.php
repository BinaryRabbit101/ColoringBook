<?php

namespace App\Services\Authoring;

use App\Actions\Admin\StagePackDirectory;
use App\Models\Asset;
use Illuminate\Support\Facades\Storage;

/**
 * Scratch directories for the authoring flows (BL-24, §10.3).
 *
 * Two things happen outside the database in web authoring — mapping a page and
 * building a pack directory to publish — and both need the same primitive:
 * *materialise some content-addressed assets as a plain tree of files, then
 * throw the tree away*. The content-addressed store is the durable copy; a
 * workspace is always disposable, and nothing in it is ever the source of
 * truth.
 *
 * `discard()` is delegated to `StagePackDirectory` rather than copied: there is
 * one recursive-delete of a staging tree in this application and it stays that
 * way.
 */
class AuthoringWorkspace
{
    public function __construct(private readonly StagePackDirectory $staging) {}

    /**
     * A fresh, empty, unguessable scratch directory.
     */
    public function create(string $prefix = 'authoring'): string
    {
        $directory = storage_path('app/private/staging/'.$prefix.'-'.bin2hex(random_bytes(8)));
        $this->ensure($directory);

        return $directory;
    }

    /**
     * Write an asset's bytes to `$target` (absolute), creating directories.
     *
     * Returns false when the blob is gone from the assets disk — which is a
     * real state (a hand-pruned disk) and one the caller must report rather
     * than publish around.
     */
    public function materialise(Asset $asset, string $target): bool
    {
        $disk = Storage::disk((string) config('coloringbook.storage.assets_disk'));

        if (! $disk->exists($asset->storage_path)) {
            return false;
        }

        $this->ensure(dirname($target));
        file_put_contents($target, (string) $disk->get($asset->storage_path));

        return true;
    }

    public function discard(string $directory): void
    {
        $this->staging->discard($directory);
    }

    public function ensure(string $directory): void
    {
        if (! is_dir($directory)) {
            mkdir($directory, 0775, true);
        }
    }
}
