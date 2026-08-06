<?php

namespace App\Actions\Packs;

use App\Exceptions\PackPublishException;
use App\Models\Asset;
use App\Models\Book;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\Page;
use App\Services\PackManifest;
use App\Services\PackManifestValidator;
use Illuminate\Contracts\Filesystem\Filesystem;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use ZipArchive;

/**
 * Import a built pack directory and publish it as the pack's next version
 * (DLC_SERVER.md §7.2, §7.3, §10.2).
 *
 * The pack builder is a dev-box tool: it walks `resources/books/<book>/`,
 * resolves each page to its artifacts and writes `manifest.json` beside them.
 * This action is what turns that directory into catalog rows plus shippable
 * bytes, and it is the *only* code path that creates a `pack_versions` row —
 * `pack:publish` calls it today, WP5's admin upload will call it tomorrow.
 *
 * Three invariants it exists to enforce:
 *
 * 1. **Versions are immutable and the server assigns them.** Publishing the
 *    same directory twice produces v1 then v2; nothing ever rewrites a
 *    published row. The manifest's own `pack_version` is advisory and gets
 *    overwritten with the assigned number (§7.3).
 * 2. **Assets are content-addressed.** Every file lands at
 *    `assets/<sha256[0:2]>/<sha256>`, so republishing a pack where one page
 *    changed re-copies one page (§5).
 * 3. **The installed tree is self-describing.** Each book gets a `book.json`
 *    — synthesised from its manifest entry when the builder didn't supply one
 *    — so a `user://dlc` folder can be inspected, or hand-seeded during
 *    development, without the manifest (§7.2).
 */
class PublishPackDirectory
{
    public function __construct(private readonly PackManifestValidator $validator) {}

    /**
     * @param  string|null  $slugOverride  `--pack=` on the CLI: publish this
     *                                     directory under a different slug
     *                                     than the manifest declares.
     * @param  bool|null  $isFree  Force the pack's free flag; null keeps
     *                             whatever the manifest or the existing row
     *                             says.
     *
     * @throws PackPublishException
     */
    public function handle(string $directory, ?string $slugOverride = null, ?bool $isFree = null): PublishedPack
    {
        $directory = rtrim($directory, "/\\ \t\n\r\0\x0B");

        if (! is_dir($directory)) {
            throw new PackPublishException([sprintf('"%s" is not a directory.', $directory)]);
        }

        $manifestPath = $directory.DIRECTORY_SEPARATOR.PackManifest::FILENAME;

        if (! is_file($manifestPath)) {
            throw new PackPublishException([sprintf('%s is missing from "%s".', PackManifest::FILENAME, $directory)]);
        }

        $manifest = PackManifest::fromJson((string) file_get_contents($manifestPath));

        $slug = $slugOverride !== null && trim($slugOverride) !== ''
            ? Str::lower(trim($slugOverride))
            : $manifest->slug();

        if ($slug === '' || Str::slug($slug) !== $slug) {
            throw new PackPublishException([
                sprintf('"%s" is not a usable pack slug — lowercase letters, digits and hyphens only.', $slug),
            ]);
        }

        // Validate against the slug we're actually publishing under, so the
        // "book_uid belongs to another pack" check can't misfire on --pack.
        $manifest = new PackManifest([...$manifest->data, 'pack_slug' => $slug]);

        $errors = $this->validator->validate($manifest, $directory);

        if ($errors !== []) {
            throw new PackPublishException($errors);
        }

        return DB::transaction(fn (): PublishedPack => $this->import($manifest, $directory, $slug, $isFree));
    }

    private function import(PackManifest $manifest, string $directory, string $slug, ?bool $isFree): PublishedPack
    {
        $warnings = [];

        $pack = $this->upsertPack($manifest, $slug, $isFree);
        $version = (int) ($pack->versions()->max('version') ?? 0) + 1;

        $declared = $manifest->declaredVersion();

        if ($declared !== null && $declared !== $version) {
            $warnings[] = sprintf(
                'The manifest declares pack_version %d; this server assigned v%d (versions are monotonic per pack and immutable once published).',
                $declared,
                $version,
            );
        }

        $files = $manifest->files();
        $assets = $this->importAssets($manifest, $directory, $files, $warnings);

        // Synthesised book.json files exist only in the published artifacts,
        // so they are carried as literal strings rather than paths on disk.
        $synthesised = $this->synthesiseBookFiles($manifest, $files);

        $this->rebuildCatalog($pack, $manifest, $assets);

        $minClientVersion = $manifest->minClientVersion()
            ?? (string) config('coloringbook.packs.default_min_client_version');

        $published = $manifest->published($slug, $version, $minClientVersion, $files);

        $archive = $this->writeArtifacts($published, $slug, $version, $directory, $files, $synthesised);

        /** @var PackVersion $packVersion */
        $packVersion = $pack->versions()->create([
            'version' => $version,
            'manifest' => $published->data,
            'archive_path' => $archive['path'],
            'archive_bytes' => $archive['bytes'],
            'archive_sha256' => $archive['sha256'],
            'min_client_version' => $minClientVersion,
            'published_at' => now(),
        ]);

        return new PublishedPack($packVersion, $warnings);
    }

    private function upsertPack(PackManifest $manifest, string $slug, ?bool $isFree): Pack
    {
        /** @var Pack $pack */
        $pack = Pack::query()->firstOrNew(['slug' => $slug]);

        $pack->title = $manifest->title();
        $pack->blurb = $manifest->blurb();
        $pack->cover_path = $manifest->cover();
        $pack->status = Pack::STATUS_PUBLISHED;

        $declaredFree = $manifest->data['is_free'] ?? null;

        if ($isFree !== null) {
            $pack->is_free = $isFree;
        } elseif (is_bool($declaredFree)) {
            $pack->is_free = $declaredFree;
        }

        $pack->save();

        return $pack;
    }

    /**
     * Copy every artifact into the content-addressed `assets` disk and return
     * the rows, keyed by "<pack-relative path>:<kind>" — a path can hold two
     * roles at once (a book cover that is also page one's display art).
     *
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     * @param  array<int, string>  $warnings
     * @return array<string, Asset>
     */
    private function importAssets(PackManifest $manifest, string $directory, array $files, array &$warnings): array
    {
        $roles = [];

        $cover = $manifest->cover();

        if ($cover !== null) {
            $roles[$cover.':cover'] = [$cover, 'cover'];
        }

        foreach ($manifest->books() as $book) {
            $bookCover = $book['cover'] ?? null;

            if (is_string($bookCover) && $bookCover !== '') {
                $roles[$bookCover.':cover'] = [$bookCover, 'cover'];
            }

            foreach (PackManifest::pagesOf($book) as $page) {
                foreach (['display', 'idmap', 'regions', 'mask'] as $role) {
                    $path = $page[$role] ?? null;

                    if (! is_string($path) || $path === '') {
                        continue;
                    }

                    if ($role === 'mask') {
                        $warnings[] = sprintf(
                            'The pack ships a mask ("%s"). Masks are source-only and are stored but never delivered (BL-9, §7.2).',
                            $path,
                        );
                    }

                    $roles[$path.':'.$role] = [$path, $role];
                }
            }
        }

        $disk = Storage::disk((string) config('coloringbook.storage.assets_disk'));
        $assets = [];

        foreach ($roles as $key => [$path, $kind]) {
            $assets[$key] = $this->importAsset($disk, $directory, $path, $kind, $files[$path]);
        }

        return $assets;
    }

    /**
     * @param  array{bytes: int, sha256: string}  $meta
     */
    private function importAsset(
        Filesystem $disk,
        string $directory,
        string $path,
        string $kind,
        array $meta,
    ): Asset {
        $absolute = $this->absolute($directory, $path);
        $storagePath = Asset::pathFor($meta['sha256']);

        // Content addressing: identical bytes are already there, by definition.
        if (! $disk->exists($storagePath)) {
            $handle = fopen($absolute, 'rb');

            if ($handle !== false) {
                $disk->put($storagePath, $handle);
                fclose($handle);
            }
        }

        [$width, $height] = $this->dimensions($absolute);

        /** @var Asset $asset */
        $asset = Asset::query()->firstOrCreate(
            ['sha256' => $meta['sha256'], 'kind' => $kind],
            [
                'storage_path' => $storagePath,
                'bytes' => $meta['bytes'],
                'mime' => $this->mimeFor($path),
                'width' => $width,
                'height' => $height,
            ],
        );

        return $asset;
    }

    /**
     * Books and pages always describe the *latest* published version, so the
     * pack's rows are rebuilt rather than merged. Progress and paint are keyed
     * by `book_uid` and page index, never by these ids, so nothing a child
     * painted depends on them surviving (§6.1).
     *
     * @param  array<string, Asset>  $assets
     */
    private function rebuildCatalog(Pack $pack, PackManifest $manifest, array $assets): void
    {
        /** @var array<int, int> $bookIds */
        $bookIds = $pack->books()->pluck('id')->all();

        if ($bookIds !== []) {
            Page::query()->whereIn('book_id', $bookIds)->delete();
            Book::query()->whereIn('id', $bookIds)->delete();
        }

        foreach ($manifest->books() as $order => $bookData) {
            $bookCover = $bookData['cover'] ?? null;

            /** @var Book $book */
            $book = $pack->books()->create([
                'book_uid' => trim((string) $bookData['book_uid']),
                'title' => trim((string) $bookData['title']),
                'cover_asset_id' => is_string($bookCover)
                    ? ($assets[$bookCover.':cover']->id ?? null)
                    : null,
                'sort_order' => $order,
            ]);

            foreach (PackManifest::pagesOf($bookData) as $position => $pageData) {
                /** @var array{0: int, 1: int} $size */
                $size = $pageData['image_size'];
                $mask = $pageData['mask'] ?? null;
                $title = $pageData['title'] ?? null;

                $book->pages()->create([
                    'page_index' => is_int($pageData['page_index'] ?? null) ? $pageData['page_index'] : $position,
                    'title' => is_string($title) ? $title : null,
                    'display_asset_id' => $assets[$pageData['display'].':display']->id,
                    // Null is the ordinary case: the mask is optional and
                    // source-only (BL-9 / BL-12).
                    'mask_asset_id' => is_string($mask) && $mask !== ''
                        ? ($assets[$mask.':mask']->id ?? null)
                        : null,
                    'idmap_asset_id' => $assets[$pageData['idmap'].':idmap']->id,
                    'regions_asset_id' => $assets[$pageData['regions'].':regions']->id,
                    'image_w' => $size[0],
                    'image_h' => $size[1],
                    'region_count' => (int) $pageData['region_count'],
                ]);
            }
        }
    }

    /**
     * `books/<book_uid>/book.json` for every book that didn't ship one, added
     * to the file map so it is covered by a digest like everything else.
     *
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     * @return array<string, string> path → literal contents
     */
    private function synthesiseBookFiles(PackManifest $manifest, array &$files): array
    {
        $synthesised = [];

        foreach ($manifest->books() as $book) {
            $path = 'books/'.trim((string) $book['book_uid']).'/book.json';

            if (array_key_exists($path, $files)) {
                continue;
            }

            $contents = (string) json_encode(
                $book,
                JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE,
            );

            $synthesised[$path] = $contents;
            $files[$path] = ['bytes' => strlen($contents), 'sha256' => hash('sha256', $contents)];
        }

        return $synthesised;
    }

    /**
     * Write the two shipped forms of a release: `pack.zip` for a first
     * install, and the unpacked `files/` tree the delta route serves from
     * (§5 "Storage layout", §7.4).
     *
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     * @param  array<string, string>  $synthesised
     * @return array{path: string, bytes: int, sha256: string}
     */
    private function writeArtifacts(
        PackManifest $published,
        string $slug,
        int $version,
        string $directory,
        array $files,
        array $synthesised,
    ): array {
        $disk = Storage::disk((string) config('coloringbook.storage.packs_disk'));
        $base = PackVersion::directoryFor($slug, $version);
        $json = $published->toJson();

        $disk->put($base.'/'.PackManifest::FILENAME, $json);

        foreach (array_keys($files) as $path) {
            $target = $base.'/files/'.$path;

            if (array_key_exists($path, $synthesised)) {
                $disk->put($target, $synthesised[$path]);

                continue;
            }

            $handle = fopen($this->absolute($directory, $path), 'rb');

            if ($handle !== false) {
                $disk->put($target, $handle);
                fclose($handle);
            }
        }

        $temporary = (string) tempnam(sys_get_temp_dir(), 'pack');

        try {
            $zip = new ZipArchive;

            if ($zip->open($temporary, ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) {
                throw new PackPublishException(['The pack archive could not be created.']);
            }

            $zip->addFromString(PackManifest::FILENAME, $json);

            foreach (array_keys($files) as $path) {
                if (array_key_exists($path, $synthesised)) {
                    $zip->addFromString($path, $synthesised[$path]);

                    continue;
                }

                $zip->addFile($this->absolute($directory, $path), $path);
            }

            $zip->close();

            $archivePath = $base.'/pack.zip';
            $handle = fopen($temporary, 'rb');

            if ($handle !== false) {
                $disk->put($archivePath, $handle);
                fclose($handle);
            }

            return [
                'path' => $archivePath,
                'bytes' => (int) filesize($temporary),
                'sha256' => (string) hash_file('sha256', $temporary),
            ];
        } finally {
            if (is_file($temporary)) {
                unlink($temporary);
            }
        }
    }

    private function absolute(string $directory, string $path): string
    {
        return $directory.DIRECTORY_SEPARATOR.str_replace('/', DIRECTORY_SEPARATOR, $path);
    }

    /**
     * @return array{0: int|null, 1: int|null}
     */
    private function dimensions(string $absolute): array
    {
        $size = @getimagesize($absolute);

        return $size === false ? [null, null] : [(int) $size[0], (int) $size[1]];
    }

    private function mimeFor(string $path): string
    {
        return match (Str::lower(pathinfo($path, PATHINFO_EXTENSION))) {
            'png' => 'image/png',
            'json' => 'application/json',
            'jpg', 'jpeg' => 'image/jpeg',
            'webp' => 'image/webp',
            default => 'application/octet-stream',
        };
    }
}
