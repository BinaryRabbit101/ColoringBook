<?php

namespace App\Services;

/**
 * The three files a page is made of, as absolute paths, plus what the
 * manifest claimed about them.
 *
 * It exists so `PackValidation` has one entry point per *page* rather than a
 * six-argument method: the pixel checks are the interesting part of WP5 and
 * they need to be unit-testable against a bare directory of PNGs, with no
 * manifest and no database in sight.
 *
 * `mask` is deliberately absent. The outline mask is optional and source-only
 * — it is stored so a page can be re-mapped later, never shipped, never
 * rendered, and never part of the display/ID-map contract (BL-9 / BL-12).
 */
final readonly class PageArtifacts
{
    /**
     * @param  string  $label  How this page is named in an error message.
     * @param  array{0: int, 1: int}|null  $declaredSize  The manifest's
     *                                                    `image_size`, when
     *                                                    there is a manifest.
     * @param  int|null  $declaredRegionCount  The manifest's `region_count`.
     */
    public function __construct(
        public string $label,
        public string $displayPath,
        public string $idmapPath,
        public string $regionsPath,
        public ?array $declaredSize = null,
        public ?int $declaredRegionCount = null,
    ) {}

    /**
     * A page in a plain directory: `<dir>/<stem>.png`, `<stem>_idmap.png`,
     * `<stem>_regions.json` — the exact naming the mapping pipeline writes.
     */
    public static function inDirectory(string $directory, string $stem = 'page_01', ?string $label = null): self
    {
        $base = rtrim($directory, '/\\').DIRECTORY_SEPARATOR.$stem;

        return new self(
            $label ?? $stem,
            $base.'.png',
            $base.'_idmap.png',
            $base.'_regions.json',
        );
    }

    /**
     * Are all three files actually there? When they are not, the *structural*
     * validator has already said so in better words and the pixel checks stay
     * quiet rather than reporting the same missing file twice.
     */
    public function complete(): bool
    {
        return is_file($this->displayPath)
            && is_file($this->idmapPath)
            && is_file($this->regionsPath);
    }
}
