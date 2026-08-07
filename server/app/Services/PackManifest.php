<?php

namespace App\Services;

use App\Exceptions\PackPublishException;
use App\Models\Pack;
use Illuminate\Support\Str;
use JsonException;

/**
 * The §7.2 `manifest.json`, as a value object.
 *
 * A pack is a plain data zip (§7.1) — no `.pck`, no scripts, nothing that can
 * execute — so the manifest is the entire contract between the dev-box pack
 * builder and this server. It is read here, validated by
 * `PackManifestValidator`, stored verbatim on `pack_versions.manifest`, and
 * from then on it is the authority for what the delta route will serve.
 *
 * @phpstan-type ManifestFile array{bytes: int, sha256: string}
 */
class PackManifest
{
    /**
     * The manifest's own filename inside a pack — never listed in `files`,
     * since a document cannot carry its own digest.
     */
    public const FILENAME = 'manifest.json';

    /**
     * @param  array<string, mixed>  $data
     */
    final public function __construct(public readonly array $data) {}

    /**
     * @throws PackPublishException when the bytes are not a JSON object.
     */
    public static function fromJson(string $json): static
    {
        try {
            /** @var mixed $decoded */
            $decoded = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
        } catch (JsonException $e) {
            throw new PackPublishException(['manifest.json is not valid JSON: '.$e->getMessage()], $e);
        }

        if (! is_array($decoded) || array_is_list($decoded)) {
            throw new PackPublishException(['manifest.json must be a JSON object.']);
        }

        /** @var array<string, mixed> $decoded */
        return new static($decoded);
    }

    /**
     * Is `$path` something we are willing to read from, or write into, a pack
     * tree?
     *
     * This is the single definition of a safe pack-relative path, used both
     * when publishing and when serving `/packs/{slug}/files/{path}`. It is
     * belt-and-braces: the delta route *also* requires the path to be a key
     * in the manifest's `files` map, so an attacker would have to get a
     * traversal past the publisher first.
     *
     * Rejected: absolute paths, Windows separators and drive letters, any
     * `.`/`..` segment, empty segments (which collapse `a//../b`), control
     * characters, and anything longer than a sane filesystem allows.
     */
    public static function isSafeRelativePath(string $path): bool
    {
        if ($path === '' || strlen($path) > 1024) {
            return false;
        }

        if (str_contains($path, "\0") || preg_match('/[\x00-\x1f]/', $path) === 1) {
            return false;
        }

        if (str_contains($path, '\\') || Str::startsWith($path, '/') || preg_match('/^[A-Za-z]:/', $path) === 1) {
            return false;
        }

        foreach (explode('/', $path) as $segment) {
            if ($segment === '' || $segment === '.' || $segment === '..') {
                return false;
            }
        }

        return true;
    }

    public function slug(): string
    {
        return $this->string('pack_slug') ?? '';
    }

    public function title(): string
    {
        return $this->string('title') ?? '';
    }

    public function blurb(): ?string
    {
        return $this->string('blurb');
    }

    public function cover(): ?string
    {
        return $this->string('cover');
    }

    public function manifestVersion(): ?int
    {
        $value = $this->data['manifest_version'] ?? null;

        return is_int($value) ? $value : null;
    }

    /**
     * What the *builder* thought this release was numbered. Advisory only:
     * versions are assigned by the server, monotonically per pack (§7.3).
     */
    public function declaredVersion(): ?int
    {
        $value = $this->data['pack_version'] ?? null;

        return is_int($value) ? $value : null;
    }

    public function minClientVersion(): ?string
    {
        return $this->string('min_client_version');
    }

    /**
     * What this pack CARRIES (BL-37, §7.2): `book` or `sticker_set`.
     *
     * **Absent means `book`**, and that is the whole back-compatibility story:
     * every manifest written before BL-37 has no `kind` key, and every one of
     * them is a colouring book. An unrecognised value is returned verbatim so
     * `PackManifestValidator` can say what it was rather than silently treating
     * a future pack as a book.
     */
    public function kind(): string
    {
        return $this->string('kind') ?? Pack::KIND_BOOK;
    }

    public function isStickerSet(): bool
    {
        return $this->kind() === Pack::KIND_STICKER_SET;
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    public function books(): array
    {
        $books = $this->data['books'] ?? null;

        if (! is_array($books)) {
            return [];
        }

        $out = [];

        foreach ($books as $book) {
            if (is_array($book)) {
                /** @var array<string, mixed> $book */
                $out[] = $book;
            }
        }

        return $out;
    }

    /**
     * @param  array<string, mixed>  $book
     * @return array<int, array<string, mixed>>
     */
    public static function pagesOf(array $book): array
    {
        return self::listOf($book, 'pages');
    }

    /**
     * The sticker sets a `sticker_set` pack carries (BL-37) — the payload array
     * `books[]` is for a book pack. Same shape of entry, same self-describing
     * per-set JSON inside the install tree.
     *
     * @return array<int, array<string, mixed>>
     */
    public function stickerSets(): array
    {
        return self::listOf($this->data, 'sticker_sets');
    }

    /**
     * @param  array<string, mixed>  $set
     * @return array<int, array<string, mixed>>
     */
    public static function stickersOf(array $set): array
    {
        return self::listOf($set, 'stickers');
    }

    /**
     * The `$key` member of `$from` as a list of objects, ignoring anything that
     * is not one. One reader for `books[]`, `pages[]`, `sticker_sets[]` and
     * `stickers[]`, because four copies of the same three lines is four places
     * to disagree about what a malformed entry means.
     *
     * @param  array<string, mixed>  $from
     * @return array<int, array<string, mixed>>
     */
    private static function listOf(array $from, string $key): array
    {
        $items = $from[$key] ?? null;

        if (! is_array($items)) {
            return [];
        }

        $out = [];

        foreach ($items as $item) {
            if (is_array($item)) {
                /** @var array<string, mixed> $item */
                $out[] = $item;
            }
        }

        return $out;
    }

    /**
     * The per-file `{bytes, sha256}` map that makes delta updates possible.
     *
     * @return array<string, ManifestFile>
     */
    public function files(): array
    {
        $files = $this->data['files'] ?? null;

        if (! is_array($files)) {
            return [];
        }

        $out = [];

        foreach ($files as $path => $meta) {
            if (! is_string($path) || ! is_array($meta)) {
                continue;
            }

            $out[$path] = [
                'bytes' => is_int($meta['bytes'] ?? null) ? $meta['bytes'] : 0,
                'sha256' => is_string($meta['sha256'] ?? null) ? strtolower($meta['sha256']) : '',
            ];
        }

        return $out;
    }

    /**
     * A copy of this manifest with the server's authoritative slug, version
     * and file map written in — what actually ships inside the zip.
     *
     * @param  array<string, ManifestFile>  $files
     */
    public function published(string $slug, int $version, string $minClientVersion, array $files): static
    {
        $data = $this->data;

        $data['manifest_version'] = (int) config('coloringbook.packs.manifest_version');
        // Written out explicitly even when it is the default, so a published
        // manifest always says what it carries and an installed client never has
        // to know that an absent key means `book` (BL-37).
        $data['kind'] = $this->kind();
        $data['pack_slug'] = $slug;
        $data['pack_version'] = $version;
        $data['min_client_version'] = $minClientVersion;

        ksort($files);
        $data['files'] = $files;

        return new static($data);
    }

    public function toJson(): string
    {
        return (string) json_encode(
            $this->data,
            JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE,
        );
    }

    private function string(string $key): ?string
    {
        $value = $this->data[$key] ?? null;

        return is_string($value) && trim($value) !== '' ? trim($value) : null;
    }
}
