<?php

namespace App\Services;

use App\Exceptions\PackPublishException;
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
        $pages = $book['pages'] ?? null;

        if (! is_array($pages)) {
            return [];
        }

        $out = [];

        foreach ($pages as $page) {
            if (is_array($page)) {
                /** @var array<string, mixed> $page */
                $out[] = $page;
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
