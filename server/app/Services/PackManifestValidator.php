<?php

namespace App\Services;

use App\Models\Book;
use App\Models\Pack;
use App\Models\StickerSet;

/**
 * Structural validation of a built pack directory (DLC_SERVER.md §7.2).
 *
 * Deliberately *only* structural: does the manifest parse, does every path it
 * names exist, does every digest match, is every `book_uid` present and
 * unique. The pixel-level checks — display/idmap dimensions agreeing, the
 * JSON-ids ↔ idmap-colours bijection, the giant-region check — are §10.1's
 * job and belong to WP5's `PackValidation`; they run over the same imported
 * rows this class produces.
 *
 * What this *does* catch is the failure that actually happens in practice:
 * a half-rebuilt pack directory where the manifest and the files came from
 * different runs.
 */
class PackManifestValidator
{
    /**
     * @return array<int, string> every problem found, empty when the pack is good
     */
    public function validate(PackManifest $manifest, string $directory): array
    {
        $errors = [];

        $this->checkHeader($manifest, $errors);
        $files = $this->checkFileMap($manifest, $errors);
        $this->checkCover($manifest, $files, $errors);

        // BL-37: the KIND decides which payload array has to be there. Nothing
        // else about a pack changes with it — the header, the file map, the
        // digests on disk and the delta route are identical for both.
        if ($manifest->isStickerSet()) {
            $this->checkStickerSets($manifest, $files, $errors);
        } else {
            $this->checkBooks($manifest, $files, $errors);
        }

        $this->checkFilesOnDisk($files, $directory, $errors);

        return $errors;
    }

    /**
     * @param  array<int, string>  $errors
     */
    private function checkHeader(PackManifest $manifest, array &$errors): void
    {
        /** @var array<int, int> $supported */
        $supported = config('coloringbook.packs.supported_manifest_versions');
        $version = $manifest->manifestVersion();

        if ($version === null) {
            $errors[] = 'manifest_version is missing or not an integer.';
        } elseif (! in_array($version, $supported, true)) {
            $errors[] = sprintf(
                'manifest_version %d is not supported (this server reads %s).',
                $version,
                implode(', ', array_map(strval(...), $supported)),
            );
        }

        if ($manifest->slug() === '') {
            $errors[] = 'pack_slug is missing or empty.';
        }

        if ($manifest->title() === '') {
            $errors[] = 'title is missing or empty.';
        }

        $declared = $manifest->declaredVersion();

        if ($declared !== null && $declared < 1) {
            $errors[] = 'pack_version must be a positive integer.';
        }

        if (! in_array($manifest->kind(), Pack::KINDS, true)) {
            $errors[] = sprintf(
                'kind "%s" is not content this server serves (%s).',
                $manifest->kind(),
                implode(', ', Pack::KINDS),
            );
        }
    }

    /**
     * @param  array<int, string>  $errors
     * @return array<string, array{bytes: int, sha256: string}>
     */
    private function checkFileMap(PackManifest $manifest, array &$errors): array
    {
        $raw = $manifest->data['files'] ?? null;

        if (! is_array($raw) || $raw === []) {
            $errors[] = 'files must be a non-empty object mapping pack-relative paths to {bytes, sha256}.';

            return [];
        }

        $files = $manifest->files();

        foreach ($files as $path => $meta) {
            if ($path === PackManifest::FILENAME) {
                $errors[] = 'files must not list manifest.json — a manifest cannot carry its own digest.';

                continue;
            }

            if (! PackManifest::isSafeRelativePath($path)) {
                $errors[] = sprintf('files["%s"] is not a safe pack-relative path.', $path);

                continue;
            }

            if ($meta['bytes'] < 0) {
                $errors[] = sprintf('files["%s"].bytes must be a non-negative integer.', $path);
            }

            if (preg_match('/^[0-9a-f]{64}$/', $meta['sha256']) !== 1) {
                $errors[] = sprintf('files["%s"].sha256 must be a 64-character hex digest.', $path);
            }
        }

        return $files;
    }

    /**
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     * @param  array<int, string>  $errors
     */
    private function checkCover(PackManifest $manifest, array $files, array &$errors): void
    {
        $cover = $manifest->cover();

        if ($cover !== null && ! array_key_exists($cover, $files)) {
            $errors[] = sprintf('cover "%s" is not listed in files.', $cover);
        }
    }

    /**
     * A `sticker_set` pack (BL-37). Strictly simpler than a book's payload,
     * because a sticker has no regions: an id, a title and one image that the
     * file map actually lists. The pixel half is `StickerValidation`, which
     * looks at the images the way §10.1's `PackValidation` looks at pages.
     *
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     * @param  array<int, string>  $errors
     */
    private function checkStickerSets(PackManifest $manifest, array $files, array &$errors): void
    {
        $sets = $manifest->stickerSets();

        if ($sets === []) {
            $errors[] = 'sticker_sets must be a non-empty array for a sticker_set pack.';

            return;
        }

        $seenUids = [];

        foreach ($sets as $index => $set) {
            $uid = is_string($set['set_uid'] ?? null) ? trim($set['set_uid']) : '';
            $label = $uid !== '' ? sprintf('sticker set "%s"', $uid) : sprintf('sticker_sets[%d]', $index);

            if ($uid === '') {
                $errors[] = sprintf(
                    'sticker_sets[%d].set_uid is missing or empty — it is what a saved sticker placement names.',
                    $index,
                );
            } elseif (preg_match('/^[a-z0-9][a-z0-9._-]{1,63}$/i', $uid) !== 1) {
                $errors[] = sprintf('%s has a set_uid that is not a plain slug.', $label);
            } elseif (in_array($uid, $seenUids, true)) {
                $errors[] = sprintf('set_uid "%s" appears twice in this pack.', $uid);
            } else {
                $seenUids[] = $uid;

                $clash = StickerSet::query()
                    ->where('set_uid', $uid)
                    ->whereHas('pack', fn ($query) => $query->where('slug', '!=', $manifest->slug()))
                    ->exists();

                if ($clash) {
                    $errors[] = sprintf(
                        'set_uid "%s" already belongs to a different pack — uids are never reused (§6.1).',
                        $uid,
                    );
                }
            }

            if (! is_string($set['title'] ?? null) || trim((string) $set['title']) === '') {
                $errors[] = sprintf('%s has no title.', $label);
            }

            $setCover = $set['cover'] ?? null;

            if (is_string($setCover) && ! array_key_exists($setCover, $files)) {
                $errors[] = sprintf('%s cover "%s" is not listed in files.', $label, $setCover);
            }

            $this->checkStickers($set, $label, $files, $errors);
        }
    }

    /**
     * @param  array<string, mixed>  $set
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     * @param  array<int, string>  $errors
     */
    private function checkStickers(array $set, string $label, array $files, array &$errors): void
    {
        $stickers = PackManifest::stickersOf($set);

        if ($stickers === []) {
            $errors[] = sprintf('%s has no stickers.', $label);

            return;
        }

        $seenIds = [];

        foreach ($stickers as $position => $sticker) {
            $stickerLabel = sprintf('%s sticker %d', $label, $position);
            $id = is_string($sticker['sticker_id'] ?? null) ? trim($sticker['sticker_id']) : '';

            if ($id === '') {
                $errors[] = sprintf('%s has no sticker_id.', $stickerLabel);
            } elseif (preg_match('/^[a-z0-9][a-z0-9._-]{0,63}$/i', $id) !== 1) {
                $errors[] = sprintf('%s has a sticker_id that is not a plain slug ("%s").', $stickerLabel, $id);
            } elseif (in_array($id, $seenIds, true)) {
                // Within the set only: two SETS may both offer a `star`, and a
                // saved placement names the pair (§7.2).
                $errors[] = sprintf('%s repeats sticker_id "%s".', $label, $id);
            } else {
                $seenIds[] = $id;
            }

            $image = $sticker['image'] ?? null;

            if (! is_string($image) || $image === '') {
                $errors[] = sprintf('%s has no image.', $stickerLabel);
            } elseif (! array_key_exists($image, $files)) {
                $errors[] = sprintf('%s image "%s" is not listed in files.', $stickerLabel, $image);
            }

            $this->checkStickerAnim($sticker, $stickerLabel, $errors);
        }
    }

    /**
     * The optional `anim` object on a sticker entry (BL-38).
     *
     * **Absent is the normal case** and says "this is a still drawing" — the
     * shape every sticker published before BL-38 has. What is checked here is
     * only that a *present* one is the whole contract and internally consistent;
     * whether the sheet's pixels agree with the grid is `StickerValidation`'s
     * half, exactly as a page's pixels are `PackValidation`'s.
     *
     * @param  array<string, mixed>  $sticker
     * @param  array<int, string>  $errors
     */
    private function checkStickerAnim(array $sticker, string $label, array &$errors): void
    {
        $raw = $sticker['anim'] ?? null;

        if ($raw === null) {
            return;
        }

        $anim = StickerAnim::normalise($raw);

        if ($anim === null) {
            $errors[] = sprintf(
                '%s has an anim that is not {%s} with positive numbers.',
                $label,
                implode(', ', StickerAnim::KEYS),
            );

            return;
        }

        if ($anim['frames'] > $anim['hframes'] * $anim['vframes']) {
            $errors[] = sprintf(
                '%s anim says %d frames but a %dx%d sheet only holds %d.',
                $label,
                $anim['frames'],
                $anim['hframes'],
                $anim['vframes'],
                $anim['hframes'] * $anim['vframes'],
            );
        }

        if ($anim['fps'] < StickerAnim::MIN_FPS || $anim['fps'] > StickerAnim::MAX_FPS) {
            $errors[] = sprintf(
                '%s anim fps is %s, outside %d-%d.',
                $label,
                rtrim(rtrim(number_format($anim['fps'], 2, '.', ''), '0'), '.'),
                StickerAnim::MIN_FPS,
                StickerAnim::MAX_FPS,
            );
        }

        if ($anim['hframes'] > StickerAnim::MAX_GRID || $anim['vframes'] > StickerAnim::MAX_GRID) {
            $errors[] = sprintf(
                '%s anim grid is %dx%d, over the %d cell-per-side ceiling.',
                $label,
                $anim['hframes'],
                $anim['vframes'],
                StickerAnim::MAX_GRID,
            );
        }
    }

    /**
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     * @param  array<int, string>  $errors
     */
    private function checkBooks(PackManifest $manifest, array $files, array &$errors): void
    {
        $books = $manifest->books();

        if ($books === []) {
            $errors[] = 'books must be a non-empty array.';

            return;
        }

        $seenUids = [];

        foreach ($books as $index => $book) {
            $uid = is_string($book['book_uid'] ?? null) ? trim($book['book_uid']) : '';
            $label = $uid !== '' ? sprintf('book "%s"', $uid) : sprintf('books[%d]', $index);

            if ($uid === '') {
                $errors[] = sprintf('books[%d].book_uid is missing or empty — it is the identifier every save row keys off.', $index);
            } elseif (preg_match('/^[a-z0-9][a-z0-9._-]{1,63}$/i', $uid) !== 1) {
                $errors[] = sprintf('%s has a book_uid that is not a plain slug.', $label);
            } elseif (in_array($uid, $seenUids, true)) {
                $errors[] = sprintf('book_uid "%s" appears twice in this pack.', $uid);
            } else {
                $seenUids[] = $uid;

                $clash = Book::query()
                    ->where('book_uid', $uid)
                    ->whereHas('pack', fn ($query) => $query->where('slug', '!=', $manifest->slug()))
                    ->exists();

                if ($clash) {
                    $errors[] = sprintf('book_uid "%s" already belongs to a different pack — uids are never reused (§6.1).', $uid);
                }
            }

            if (! is_string($book['title'] ?? null) || trim((string) $book['title']) === '') {
                $errors[] = sprintf('%s has no title.', $label);
            }

            $bookCover = $book['cover'] ?? null;

            if (is_string($bookCover) && ! array_key_exists($bookCover, $files)) {
                $errors[] = sprintf('%s cover "%s" is not listed in files.', $label, $bookCover);
            }

            $this->checkPages($book, $label, $files, $errors);
        }
    }

    /**
     * @param  array<string, mixed>  $book
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     * @param  array<int, string>  $errors
     */
    private function checkPages(array $book, string $label, array $files, array &$errors): void
    {
        $pages = PackManifest::pagesOf($book);

        if ($pages === []) {
            $errors[] = sprintf('%s has no pages.', $label);

            return;
        }

        $seenIndexes = [];

        foreach ($pages as $position => $page) {
            $pageLabel = sprintf('%s page %d', $label, $position);
            $index = $page['page_index'] ?? null;

            if (! is_int($index) || $index < 0) {
                $errors[] = sprintf('%s has a missing or negative page_index.', $pageLabel);
            } elseif (in_array($index, $seenIndexes, true)) {
                $errors[] = sprintf('%s repeats page_index %d.', $label, $index);
            } else {
                $seenIndexes[] = $index;
            }

            // `mask` is optional per page: when the page has one, the shipped
            // display-resolution mask rides in the pack (BL-12, §7.2).
            foreach (['display', 'idmap', 'regions'] as $role) {
                $path = $page[$role] ?? null;

                if (! is_string($path) || $path === '') {
                    $errors[] = sprintf('%s has no %s.', $pageLabel, $role);
                } elseif (! array_key_exists($path, $files)) {
                    $errors[] = sprintf('%s %s "%s" is not listed in files.', $pageLabel, $role, $path);
                }
            }

            $mask = $page['mask'] ?? null;

            if (is_string($mask) && $mask !== '' && ! array_key_exists($mask, $files)) {
                $errors[] = sprintf('%s mask "%s" is not listed in files.', $pageLabel, $mask);
            }

            $size = $page['image_size'] ?? null;

            if (! is_array($size) || count($size) !== 2
                || ! is_int($size[0] ?? null) || ! is_int($size[1] ?? null)
                || (int) $size[0] < 1 || (int) $size[1] < 1) {
                $errors[] = sprintf('%s image_size must be [width, height] in positive pixels.', $pageLabel);
            }

            $regionCount = $page['region_count'] ?? null;

            if (! is_int($regionCount) || $regionCount < 1) {
                $errors[] = sprintf('%s region_count must be a positive integer.', $pageLabel);
            }
        }
    }

    /**
     * The check that catches a stale build: the manifest says one thing, the
     * bytes on disk say another.
     *
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     * @param  array<int, string>  $errors
     */
    private function checkFilesOnDisk(array $files, string $directory, array &$errors): void
    {
        foreach ($files as $path => $meta) {
            if (! PackManifest::isSafeRelativePath($path)) {
                continue; // already reported
            }

            $absolute = rtrim($directory, '/\\').DIRECTORY_SEPARATOR.str_replace('/', DIRECTORY_SEPARATOR, $path);

            if (! is_file($absolute)) {
                $errors[] = sprintf('files["%s"] does not exist in the pack directory.', $path);

                continue;
            }

            $bytes = filesize($absolute);

            if ($bytes !== false && $bytes !== $meta['bytes']) {
                $errors[] = sprintf(
                    'files["%s"] is %d bytes on disk but the manifest says %d.',
                    $path,
                    $bytes,
                    $meta['bytes'],
                );
            }

            $digest = hash_file('sha256', $absolute);

            if ($digest !== false && $digest !== $meta['sha256']) {
                $errors[] = sprintf(
                    'files["%s"] hashes to %s but the manifest says %s — the manifest and the files came from different runs.',
                    $path,
                    $digest,
                    $meta['sha256'],
                );
            }
        }
    }
}
