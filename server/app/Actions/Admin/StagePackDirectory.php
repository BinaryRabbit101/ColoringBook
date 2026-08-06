<?php

namespace App\Actions\Admin;

use App\Exceptions\PackPublishException;
use App\Models\Asset;
use App\Services\PackManifest;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use ZipArchive;

/**
 * Turn whatever the admin uploaded into a plain **pack directory on disk** —
 * the only shape `PublishPackDirectory` knows how to read.
 *
 * §11 lets `POST /admin/packs/{slug}/versions` arrive in two forms and this is
 * where they converge:
 *
 * 1. **The whole zip.** What the dev box's `pack build` produces and what a
 *    human drags into the browser. Cheap to reason about, expensive on the
 *    wire for a one-page fix.
 * 2. **A manifest plus asset ULIDs.** Every file was already uploaded to
 *    `POST /admin/assets`, so this re-materialises the tree out of the
 *    content-addressed store and a 40 MB pack becomes a few KB of JSON.
 *
 * Either way the caller gets a temporary directory it must `discard()`.
 *
 * ## Why the zip is unpacked entry by entry
 *
 * `ZipArchive::extractTo()` will happily write `../../.env`, and on a box
 * where the same PHP process serves the game it is the wrong tool. Every entry
 * is checked against `PackManifest::isSafeRelativePath()` — the *same*
 * definition the publisher and the delta route use, so there is one answer to
 * "is this path allowed" in the whole application — and the total unpacked
 * size is capped, because a zip bomb is a one-line denial of service
 * otherwise.
 */
class StagePackDirectory
{
    /**
     * Directory entries are `dir/`; nothing about a pack needs them, and
     * skipping them keeps the traversal check to one shape of input.
     */
    private const DIRECTORY_SUFFIX = '/';

    /**
     * Unpack an uploaded `pack.zip` into a scratch directory.
     *
     * @throws PackPublishException
     */
    public function fromZip(UploadedFile $zip): string
    {
        $archive = new ZipArchive;

        if ($archive->open($zip->getRealPath()) !== true) {
            throw new PackPublishException(['The upload is not a readable zip archive.']);
        }

        $directory = $this->scratchDirectory();
        $budget = ((int) config('coloringbook.admin.max_upload_kb')) * 1024 * 20;
        $written = 0;
        $errors = [];

        try {
            for ($i = 0; $i < $archive->numFiles; $i++) {
                $name = $archive->getNameIndex($i);

                if ($name === false || str_ends_with($name, self::DIRECTORY_SUFFIX)) {
                    continue;
                }

                $name = str_replace('\\', '/', $name);

                if ($name !== PackManifest::FILENAME && ! PackManifest::isSafeRelativePath($name)) {
                    $errors[] = sprintf('The archive contains an unsafe path ("%s").', $name);

                    continue;
                }

                $stream = $archive->getStream($name);

                if ($stream === false) {
                    $errors[] = sprintf('"%s" could not be read out of the archive.', $name);

                    continue;
                }

                $target = $directory.DIRECTORY_SEPARATOR.str_replace('/', DIRECTORY_SEPARATOR, $name);
                $this->ensureDirectory(dirname($target));

                $out = fopen($target, 'wb');

                if ($out === false) {
                    fclose($stream);
                    $errors[] = sprintf('"%s" could not be written to the staging directory.', $name);

                    continue;
                }

                while (! feof($stream)) {
                    $chunk = fread($stream, 262144);

                    if ($chunk === false) {
                        break;
                    }

                    $written += strlen($chunk);

                    if ($written > $budget) {
                        fclose($stream);
                        fclose($out);

                        throw new PackPublishException([
                            'The archive unpacks to more than this server will accept.',
                        ]);
                    }

                    fwrite($out, $chunk);
                }

                fclose($stream);
                fclose($out);
            }
        } catch (PackPublishException $e) {
            $this->discard($directory);

            throw $e;
        } finally {
            $archive->close();
        }

        if ($errors !== []) {
            $this->discard($directory);

            throw new PackPublishException($errors);
        }

        return $directory;
    }

    /**
     * Re-materialise a pack from a manifest plus `path → asset_ulid`.
     *
     * The manifest's `files` map is the authority on which paths exist; the
     * ULID map only says where the bytes for each of them live. A path in one
     * and not the other is an error rather than a silent skip — the two came
     * from the same build or they did not.
     *
     * @param  array<string, mixed>  $manifest
     * @param  array<string, string>  $assets  pack-relative path → asset ULID
     *
     * @throws PackPublishException
     */
    public function fromAssets(array $manifest, array $assets): string
    {
        $parsed = new PackManifest($manifest);
        $files = $parsed->files();
        $errors = [];

        if ($files === []) {
            throw new PackPublishException([
                'files must be a non-empty object mapping pack-relative paths to {bytes, sha256}.',
            ]);
        }

        foreach (array_keys($assets) as $path) {
            if (! array_key_exists($path, $files)) {
                $errors[] = sprintf('An asset was supplied for "%s", which the manifest does not list.', $path);
            }
        }

        /** @var array<string, Asset> $rows */
        $rows = Asset::query()
            ->whereIn('ulid', array_values($assets))
            ->get()
            ->keyBy('ulid')
            ->all();

        $directory = $this->scratchDirectory();
        $disk = Storage::disk((string) config('coloringbook.storage.assets_disk'));

        foreach (array_keys($files) as $path) {
            $ulid = $assets[$path] ?? null;

            if ($ulid === null) {
                $errors[] = sprintf('No asset ULID was supplied for "%s".', $path);

                continue;
            }

            $asset = $rows[$ulid] ?? null;

            if ($asset === null) {
                $errors[] = sprintf('Asset "%s" (for "%s") does not exist.', $ulid, $path);

                continue;
            }

            if (! $disk->exists($asset->storage_path)) {
                $errors[] = sprintf('Asset "%s" (for "%s") has no bytes on disk.', $ulid, $path);

                continue;
            }

            $target = $directory.DIRECTORY_SEPARATOR.str_replace('/', DIRECTORY_SEPARATOR, $path);
            $this->ensureDirectory(dirname($target));
            file_put_contents($target, (string) $disk->get($asset->storage_path));
        }

        if ($errors !== []) {
            $this->discard($directory);

            throw new PackPublishException($errors);
        }

        file_put_contents(
            $directory.DIRECTORY_SEPARATOR.PackManifest::FILENAME,
            (string) json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE),
        );

        return $directory;
    }

    /**
     * Remove a staged directory. Safe to call twice.
     */
    public function discard(string $directory): void
    {
        if (! is_dir($directory)) {
            return;
        }

        /** @var iterable<\SplFileInfo> $entries */
        $entries = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($directory, \FilesystemIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::CHILD_FIRST,
        );

        foreach ($entries as $entry) {
            $entry->isDir() ? @rmdir($entry->getPathname()) : @unlink($entry->getPathname());
        }

        @rmdir($directory);
    }

    private function scratchDirectory(): string
    {
        $directory = storage_path('app/private/staging/'.bin2hex(random_bytes(8)));
        $this->ensureDirectory($directory);

        return $directory;
    }

    private function ensureDirectory(string $path): void
    {
        if (! is_dir($path)) {
            mkdir($path, 0775, true);
        }
    }
}
