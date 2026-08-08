<?php

namespace App\Actions\Packs;

use App\Exceptions\PackPublishException;
use App\Models\Asset;
use App\Models\Book;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\Page;
use App\Models\Sticker;
use App\Models\StickerSet;
use App\Services\PackManifest;
use App\Services\PackManifestValidator;
use App\Services\StickerAnim;
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
 * `pack:publish` calls it with `$publishNow = true`; WP5's admin upload calls
 * it with `false` and lets the reviewer stamp `published_at` afterwards.
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
     * @param  bool  $publishNow  `true` (the CLI's behaviour) stamps
     *                            `published_at` and marks the pack published
     *                            in one step. `false` creates the release as a
     *                            **draft**: every artifact is written and every
     *                            row exists, but `published_at` stays null and
     *                            the pack's own status is left alone, so
     *                            nothing is visible to the catalog until an
     *                            admin has looked at the region-overlay
     *                            preview and pressed publish (§10.2). WP5's
     *                            upload endpoint is the only caller that
     *                            passes `false`.
     *
     * @throws PackPublishException
     */
    public function handle(
        string $directory,
        ?string $slugOverride = null,
        ?bool $isFree = null,
        bool $publishNow = true,
    ): PublishedPack {
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

        return DB::transaction(
            fn (): PublishedPack => $this->import($manifest, $directory, $slug, $isFree, $publishNow),
        );
    }

    private function import(
        PackManifest $manifest,
        string $directory,
        string $slug,
        ?bool $isFree,
        bool $publishNow,
    ): PublishedPack {
        $warnings = [];

        $pack = $this->upsertPack($manifest, $slug, $isFree, $publishNow);
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
            'published_at' => $publishNow ? now() : null,
        ]);

        return new PublishedPack($packVersion, $warnings);
    }

    private function upsertPack(PackManifest $manifest, string $slug, ?bool $isFree, bool $publishNow): Pack
    {
        /** @var Pack $pack */
        $pack = Pack::query()->firstOrNew(['slug' => $slug]);

        $pack->title = $manifest->title();
        $pack->kind = $manifest->kind();
        $pack->blurb = $manifest->blurb();
        $pack->cover_path = $manifest->cover();

        // A draft release must never flip the pack itself into the catalog —
        // a retired pack stays retired while a fix is being drafted, and a
        // brand-new pack stays a draft until someone publishes a version.
        if ($publishNow) {
            $pack->status = Pack::STATUS_PUBLISHED;
        }

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

                    $roles[$path.':'.$role] = [$path, $role];
                }
            }
        }

        // BL-37: a sticker pack's payload is images and nothing else. One role,
        // `sticker`, in the same content-addressed store — a sticker that also
        // serves as the set's cover is one blob wearing two `assets.kind` hats,
        // exactly like page one of a one-book pack.
        foreach ($manifest->stickerSets() as $set) {
            $setCover = $set['cover'] ?? null;

            if (is_string($setCover) && $setCover !== '') {
                $roles[$setCover.':cover'] = [$setCover, 'cover'];
            }

            foreach (PackManifest::stickersOf($set) as $sticker) {
                $path = $sticker['image'] ?? null;

                if (is_string($path) && $path !== '') {
                    $roles[$path.':sticker'] = [$path, 'sticker'];
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

        /** @var array<int, int> $setIds */
        $setIds = $pack->stickerSets()->pluck('id')->all();

        if ($setIds !== []) {
            Sticker::query()->whereIn('sticker_set_id', $setIds)->delete();
            StickerSet::query()->whereIn('id', $setIds)->delete();
        }

        // Both payloads are rebuilt unconditionally, so a pack that changed kind
        // between releases (a mistake, but a possible one) cannot leave the other
        // kind's rows behind claiming a uid.
        $this->rebuildStickerSets($pack, $manifest, $assets);

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
                    // The mask is optional per page; when present it ships in
                    // the pack and renders under the display art (BL-12).
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
     * The sticker half of the catalog rebuild (BL-37).
     *
     * @param  array<string, Asset>  $assets
     */
    private function rebuildStickerSets(Pack $pack, PackManifest $manifest, array $assets): void
    {
        foreach ($manifest->stickerSets() as $order => $setData) {
            $setCover = $setData['cover'] ?? null;
            $sortOrder = $setData['sort_order'] ?? null;

            /** @var StickerSet $set */
            $set = $pack->stickerSets()->create([
                'set_uid' => trim((string) $setData['set_uid']),
                'title' => trim((string) $setData['title']),
                'cover_asset_id' => is_string($setCover)
                    ? ($assets[$setCover.':cover']->id ?? null)
                    : null,
                'sort_order' => is_int($sortOrder) ? $sortOrder : $order,
            ]);

            foreach (PackManifest::stickersOf($setData) as $position => $stickerData) {
                $asset = $assets[$stickerData['image'].':sticker'];
                $title = $stickerData['title'] ?? null;

                $set->stickers()->create([
                    'sticker_index' => is_int($stickerData['sticker_index'] ?? null)
                        ? $stickerData['sticker_index']
                        : $position,
                    'sticker_id' => trim((string) $stickerData['sticker_id']),
                    'title' => is_string($title) ? $title : null,
                    'image_asset_id' => $asset->id,
                    'image_w' => $asset->width,
                    'image_h' => $asset->height,
                    // BL-38: null for a still sticker, which is every manifest
                    // entry with no `anim` key — i.e. everything before BL-38.
                    'anim' => StickerAnim::of($stickerData),
                ]);
            }
        }
    }

    /**
     * `books/<book_uid>/book.json` for every book that didn't ship one, and
     * `stickers/<set_uid>/sticker_set.json` for every sticker set (BL-37) —
     * added to the file map so each is covered by a digest like everything else.
     *
     * This is §7.2's "the installed tree is self-describing" promise, and it is
     * exactly what the client's `StickerSetDef.discover()` reads: it scans
     * `user://dlc/<pack>/stickers/<set>/sticker_set.json` and never opens the
     * manifest, the same way `BookDef` reads only `book.json`.
     *
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     * @return array<string, string> path → literal contents
     */
    private function synthesiseBookFiles(PackManifest $manifest, array &$files): array
    {
        $synthesised = [];

        foreach ($manifest->books() as $book) {
            $path = 'books/'.trim((string) $book['book_uid']).'/book.json';
            $this->synthesise($path, $book, $files, $synthesised);
        }

        foreach ($manifest->stickerSets() as $set) {
            $path = 'stickers/'.trim((string) $set['set_uid']).'/sticker_set.json';
            $this->synthesise($path, $set, $files, $synthesised);
        }

        return $synthesised;
    }

    /**
     * @param  array<string, mixed>  $entry
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     * @param  array<string, string>  $synthesised
     */
    private function synthesise(string $path, array $entry, array &$files, array &$synthesised): void
    {
        if (array_key_exists($path, $files)) {
            return;
        }

        $contents = (string) json_encode(
            $entry,
            JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE,
        );

        $synthesised[$path] = $contents;
        $files[$path] = ['bytes' => strlen($contents), 'sha256' => hash('sha256', $contents)];
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
