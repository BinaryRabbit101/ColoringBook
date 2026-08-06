<?php

namespace App\Services;

use App\Models\Book;

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
        $this->checkBooks($manifest, $files, $errors);
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
    private function checkBooks(PackManifest $manifest, array $files, array &$errors): void
    {
        $cover = $manifest->cover();

        if ($cover !== null && ! array_key_exists($cover, $files)) {
            $errors[] = sprintf('cover "%s" is not listed in files.', $cover);
        }

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

            // `mask` is optional and normally absent: the outline mask is
            // source-only and never ships (BL-9 / BL-12, §7.2).
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
