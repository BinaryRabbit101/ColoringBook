<?php

namespace App\Services\Mapping;

/**
 * One run of the mapping pipeline over one page, laid out on disk (BL-24,
 * DLC_SERVER.md §10.3).
 *
 * The caller stages a scratch directory and this describes it; the runner turns
 * it into a command line. Crucially, **the artifact paths are computed here,
 * not discovered afterwards**, because the pipeline's naming rule is the
 * contract: artifacts land beside the *display* image, named from its basename
 * (`page_01.png` → `page_01_idmap.png`, `page_01_regions.json`, and on a masked
 * page `page_01_mask.png`).
 *
 * That is also why the mask **source** is staged somewhere else entirely: a
 * mask sitting at `page_01_mask.png` would be the same path the pipeline writes
 * its resample to, and the run would silently overwrite its own input.
 */
final readonly class MappingRequest
{
    /**
     * @param  string  $displayPath  Absolute path to the page's visible art.
     * @param  string|null  $maskPath  Absolute path to the artist's masking
     *                                 image, or null when the display image is
     *                                 its own mapping source (BL-9).
     * @param  array<string, float|int>  $tuning  Pipeline flags, keyed by the
     *                                            names in
     *                                            `AuthoredPage::TUNING_FLAGS`.
     */
    public function __construct(
        public string $displayPath,
        public ?string $maskPath = null,
        public array $tuning = [],
    ) {}

    /**
     * The image whose lines decide where paint may go — the mask when there is
     * one, the display art otherwise (BL-9).
     */
    public function sourcePath(): string
    {
        return $this->maskPath ?? $this->displayPath;
    }

    public function idmapPath(): string
    {
        return $this->base().'_idmap.png';
    }

    public function regionsPath(): string
    {
        return $this->base().'_regions.json';
    }

    /**
     * The display-resolution mask the pipeline resamples and the pack ships
     * (BL-12) — only written on a masked run.
     */
    public function maskArtifactPath(): ?string
    {
        return $this->maskPath === null ? null : $this->base().'_mask.png';
    }

    /**
     * Everything a successful run must have left behind.
     *
     * @return list<string>
     */
    public function expectedArtifacts(): array
    {
        $paths = [$this->idmapPath(), $this->regionsPath()];
        $mask = $this->maskArtifactPath();

        return $mask === null ? $paths : [...$paths, $mask];
    }

    private function base(): string
    {
        $extension = pathinfo($this->displayPath, PATHINFO_EXTENSION);

        return $extension === ''
            ? $this->displayPath
            : substr($this->displayPath, 0, -(strlen($extension) + 1));
    }
}
