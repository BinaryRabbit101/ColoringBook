<?php

namespace App\Services;

use JsonException;

/**
 * The §10.1 pixel checks — what the server does *instead of* running the
 * mapping pipeline (DLC_SERVER.md §10.1).
 *
 * The pipeline itself stays a dev-box tool: it is a tuning loop whose verdict
 * comes from an artist looking at the ID map, and a giant-region failure means
 * a line in the drawing has a gap, which no server job can fix. What the
 * server *can* do — cheaply, in pure PHP — is catch the failure that actually
 * happens in practice: **someone uploading artifacts that came from different
 * runs**. A stale regions JSON beside a fresh ID map produces a page where
 * taps land in the wrong shape, and nothing structural about the manifest
 * shows it.
 *
 * So this class is the complement of `PackManifestValidator`, not a
 * replacement:
 *
 * | `PackManifestValidator` | `PackValidation` |
 * |---|---|
 * | manifest parses, paths exist, digests match | the pixels agree with the JSON |
 * | runs for every publish, CLI included | runs on the admin upload path |
 *
 * ## The checks
 *
 * 1. display and ID map are readable images with **identical dimensions**
 *    (an ID map that is not pixel-for-pixel the display art is unusable);
 * 2. the regions JSON is **schema v1** and its `image_size` matches the ID map;
 * 3. the manifest's `image_size` matches the ID map;
 * 4. every `id` in the JSON appears as a distinct colour in the ID map **and
 *    vice-versa** — counted in both directions, because a one-way check
 *    passes happily on a JSON that is a subset of a newer run;
 * 5. `#000000` is present (line work is reserved, and its absence means the
 *    binarisation step never ran or the wrong file was uploaded);
 * 6. `region_count > 0`, and the manifest agrees with the JSON;
 * 7. no **giant region** — the largest region covers less than
 *    `coloringbook.admin.giant_region_fraction` of the paintable pixels.
 *    One region swallowing the page is the signature of a gap in the line art.
 *
 * Minimum-region-area is deliberately *not* re-checked here: the pipeline
 * drops specks below `--min-area` before it ever writes an ID map, so a speck
 * arriving at the server would mean the operator lowered that threshold on
 * purpose.
 *
 * ## Reading the regions JSON
 *
 * Canonical schema v1 is the mapping pipeline's own output — `version`,
 * `image_size`, `regions[{id, id_color, outline, holes, centroid, area_px}]`
 * (mapping-pipeline skill). This reader is deliberately tolerant of two
 * spellings that exist in the wild: `schema_version` for `version`, and an
 * `id` that is already a `#RRGGBB` string rather than the packed integer.
 * Both resolve to the same region colour, which is the only thing the
 * bijection cares about.
 */
class PackValidation
{
    /**
     * Schema versions of `*_regions.json` this server can read.
     */
    private const SUPPORTED_SCHEMA_VERSIONS = [1];

    /**
     * Every page in a built pack directory.
     *
     * Pages whose files are missing are skipped in silence — `PackManifestValidator`
     * reports those, and saying it twice in one `errors[]` list helps nobody.
     */
    public function validate(PackManifest $manifest, string $directory): PackValidationResult
    {
        RegionImage::assertSupported();

        $result = new PackValidationResult;

        foreach ($manifest->books() as $index => $book) {
            $uid = is_string($book['book_uid'] ?? null) && trim($book['book_uid']) !== ''
                ? trim($book['book_uid'])
                : sprintf('books[%d]', $index);

            foreach (PackManifest::pagesOf($book) as $position => $page) {
                $artifacts = $this->artifactsFor($directory, $uid, $position, $page);

                if ($artifacts === null || ! $artifacts->complete()) {
                    continue;
                }

                $result = $result->merge($this->validatePage($artifacts));
            }
        }

        return $result;
    }

    /**
     * One page, against nothing but the files on disk. This is the unit of
     * §10.1 and the unit the tests exercise.
     */
    public function validatePage(PageArtifacts $page): PackValidationResult
    {
        RegionImage::assertSupported();

        $errors = [];
        $warnings = [];

        $idmap = RegionImage::fromPath($page->idmapPath);
        $display = RegionImage::fromPath($page->displayPath);

        try {
            if ($idmap === null) {
                return PackValidationResult::failed([
                    sprintf('%s: the ID map is not a readable image.', $page->label),
                ]);
            }

            if ($display === null) {
                return PackValidationResult::failed([
                    sprintf('%s: the display art is not a readable image.', $page->label),
                ]);
            }

            if (! $display->sizeMatches($idmap)) {
                // Everything after this compares pixels between the two, so
                // there is nothing useful left to say about this page.
                return PackValidationResult::failed([
                    sprintf(
                        '%s: the display art is %dx%d but the ID map is %dx%d — they must be identical, or hit-testing lands in the wrong shape.',
                        $page->label,
                        $display->width,
                        $display->height,
                        $idmap->width,
                        $idmap->height,
                    ),
                ]);
            }

            if ($page->declaredSize !== null
                && ($page->declaredSize[0] !== $idmap->width || $page->declaredSize[1] !== $idmap->height)) {
                $errors[] = sprintf(
                    '%s: the manifest declares image_size [%d, %d] but the artwork is %dx%d.',
                    $page->label,
                    $page->declaredSize[0],
                    $page->declaredSize[1],
                    $idmap->width,
                    $idmap->height,
                );
            }

            $counts = $idmap->colourCounts();
            $black = $counts[RegionImage::LINE_COLOUR] ?? 0;
            unset($counts[RegionImage::LINE_COLOUR]);

            if ($black === 0) {
                $errors[] = sprintf(
                    '%s: the ID map has no #000000 pixels — line work is the reserved unpaintable colour, so an ID map without it was never binarised.',
                    $page->label,
                );
            }

            $regions = $this->readRegions($page, $idmap, $errors, $warnings);

            if ($regions !== null) {
                $this->checkBijection($page, $regions, $counts, $errors);
                $this->checkAreas($page, $regions, $counts, $warnings);
                $this->checkCounts($page, $regions, $errors);
            }

            $this->checkGiantRegion($page, $counts, $errors);

            return new PackValidationResult($errors, $warnings);
        } finally {
            $idmap?->destroy();
            $display?->destroy();
        }
    }

    /**
     * Parse `*_regions.json` into `colour => region`, or null when the file is
     * unusable (in which case the errors say why).
     *
     * @param  list<string>  $errors
     * @param  list<string>  $warnings
     * @return array<int, array{colour: int, area: int|null}>|null
     */
    private function readRegions(
        PageArtifacts $page,
        RegionImage $idmap,
        array &$errors,
        array &$warnings,
    ): ?array {
        $raw = @file_get_contents($page->regionsPath);

        if ($raw === false) {
            $errors[] = sprintf('%s: the regions JSON could not be read.', $page->label);

            return null;
        }

        try {
            /** @var mixed $decoded */
            $decoded = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
        } catch (JsonException $e) {
            $errors[] = sprintf('%s: the regions JSON is not valid JSON (%s).', $page->label, $e->getMessage());

            return null;
        }

        if (! is_array($decoded) || array_is_list($decoded)) {
            $errors[] = sprintf('%s: the regions JSON must be an object.', $page->label);

            return null;
        }

        /** @var array<string, mixed> $decoded */
        $schema = $decoded['version'] ?? $decoded['schema_version'] ?? null;

        if (! is_int($schema) || ! in_array($schema, self::SUPPORTED_SCHEMA_VERSIONS, true)) {
            $errors[] = sprintf(
                '%s: the regions JSON is schema version %s; this server reads %s.',
                $page->label,
                is_int($schema) ? (string) $schema : 'unknown',
                implode(', ', array_map(strval(...), self::SUPPORTED_SCHEMA_VERSIONS)),
            );

            return null;
        }

        $size = $decoded['image_size'] ?? null;

        if (! is_array($size) || ! is_int($size[0] ?? null) || ! is_int($size[1] ?? null)) {
            $errors[] = sprintf('%s: the regions JSON has no usable image_size.', $page->label);
        } elseif ($size[0] !== $idmap->width || $size[1] !== $idmap->height) {
            $errors[] = sprintf(
                '%s: the regions JSON was traced at %dx%d but the ID map is %dx%d — they came from different runs.',
                $page->label,
                $size[0],
                $size[1],
                $idmap->width,
                $idmap->height,
            );
        }

        $list = $decoded['regions'] ?? null;

        if (! is_array($list) || $list === []) {
            $errors[] = sprintf('%s: the regions JSON lists no regions (region_count must be > 0).', $page->label);

            return null;
        }

        $regions = [];

        foreach ($list as $position => $region) {
            if (! is_array($region)) {
                $errors[] = sprintf('%s: regions[%s] is not an object.', $page->label, (string) $position);

                continue;
            }

            /** @var array<string, mixed> $region */
            $colour = $this->colourOf($region);

            if ($colour === null) {
                $errors[] = sprintf(
                    '%s: regions[%s] has no usable id — expected the packed integer id or an "#RRGGBB" id_color.',
                    $page->label,
                    (string) $position,
                );

                continue;
            }

            if ($colour === RegionImage::LINE_COLOUR) {
                $errors[] = sprintf(
                    '%s: regions[%s] claims #000000, which is reserved for line work and can never be a paintable region.',
                    $page->label,
                    (string) $position,
                );

                continue;
            }

            if (array_key_exists($colour, $regions)) {
                $errors[] = sprintf(
                    '%s: region %s appears twice in the regions JSON.',
                    $page->label,
                    RegionImage::hex($colour),
                );

                continue;
            }

            $area = $region['area_px'] ?? $region['area'] ?? null;

            $regions[$colour] = [
                'colour' => $colour,
                'area' => is_int($area) ? $area : null,
            ];
        }

        if ($regions === []) {
            $warnings[] = sprintf('%s: no region in the regions JSON could be read.', $page->label);
        }

        return $regions;
    }

    /**
     * The check that catches a stale artifact pair: the set of ids in the JSON
     * and the set of non-black colours in the ID map must be **the same set**.
     *
     * Counted in both directions on purpose. A JSON that is missing a region
     * still "validates" against a one-way check, and the page then has a shape
     * nobody can tap; a JSON with a region the ID map never drew produces a
     * debug overlay that lies.
     *
     * @param  array<int, array{colour: int, area: int|null}>  $regions
     * @param  array<int, int>  $counts  ID-map RGB → pixel count, black removed
     * @param  list<string>  $errors
     */
    private function checkBijection(PageArtifacts $page, array $regions, array $counts, array &$errors): void
    {
        $missingFromIdmap = array_diff(array_keys($regions), array_keys($counts));
        $missingFromJson = array_diff(array_keys($counts), array_keys($regions));

        if ($missingFromIdmap !== []) {
            $errors[] = sprintf(
                '%s: %d region id(s) in the regions JSON are absent from the ID map (%s).',
                $page->label,
                count($missingFromIdmap),
                $this->listColours($missingFromIdmap),
            );
        }

        if ($missingFromJson !== []) {
            $errors[] = sprintf(
                '%s: %d colour(s) in the ID map are absent from the regions JSON (%s).',
                $page->label,
                count($missingFromJson),
                $this->listColours($missingFromJson),
            );
        }
    }

    /**
     * `area_px` counts ID-map pixels, so a disagreement is a *warning*: it
     * means the JSON is one run behind, which the bijection may not catch when
     * only shapes moved. Not fatal — the ID map is what the game hit-tests
     * against, and the polygons are debug-overlay data.
     *
     * @param  array<int, array{colour: int, area: int|null}>  $regions
     * @param  array<int, int>  $counts
     * @param  list<string>  $warnings
     */
    private function checkAreas(PageArtifacts $page, array $regions, array $counts, array &$warnings): void
    {
        foreach ($regions as $colour => $region) {
            $declared = $region['area'];
            $actual = $counts[$colour] ?? null;

            if ($declared === null || $actual === null || $declared === $actual) {
                continue;
            }

            $warnings[] = sprintf(
                '%s: region %s says area %d but covers %d ID-map pixels.',
                $page->label,
                RegionImage::hex($colour),
                $declared,
                $actual,
            );
        }
    }

    /**
     * @param  array<int, array{colour: int, area: int|null}>  $regions
     * @param  list<string>  $errors
     */
    private function checkCounts(PageArtifacts $page, array $regions, array &$errors): void
    {
        if ($page->declaredRegionCount === null) {
            return;
        }

        if ($page->declaredRegionCount !== count($regions)) {
            $errors[] = sprintf(
                '%s: the manifest declares region_count %d but the regions JSON has %d.',
                $page->label,
                $page->declaredRegionCount,
                count($regions),
            );
        }
    }

    /**
     * "One giant region" is the shape of a **gap in the line art**: the flood
     * fill leaked out of one shape into its neighbour and the whole drawing
     * came back as a single fill. The artist has to close the line — which is
     * exactly why this is an error the server reports rather than something it
     * tries to fix.
     *
     * Measured against *paintable* pixels (everything that is not line work),
     * so a page with heavy black borders isn't penalised for them.
     *
     * @param  array<int, int>  $counts  black already removed
     * @param  list<string>  $errors
     */
    private function checkGiantRegion(PageArtifacts $page, array $counts, array &$errors): void
    {
        if ($counts === []) {
            $errors[] = sprintf(
                '%s: the ID map has no paintable pixels at all — every pixel is line work.',
                $page->label,
            );

            return;
        }

        $paintable = array_sum($counts);
        $largest = max($counts);
        $fraction = (float) config('coloringbook.admin.giant_region_fraction');

        if ($paintable > 0 && $largest / $paintable >= $fraction) {
            $errors[] = sprintf(
                '%s: region %s covers %.1f%% of the paintable pixels (the limit is %.0f%%) — that is a gap in the line art, not a region.',
                $page->label,
                RegionImage::hex((int) array_search($largest, $counts, true)),
                $largest / $paintable * 100,
                $fraction * 100,
            );
        }
    }

    /**
     * @param  array<string, mixed>  $region
     */
    private function colourOf(array $region): ?int
    {
        /** @var mixed $colour */
        $colour = $region['id_color'] ?? $region['id'] ?? null;

        if (is_int($colour)) {
            return $colour & 0xFFFFFF;
        }

        if (is_string($colour) && preg_match('/^#?([0-9a-f]{6})$/i', trim($colour), $matches) === 1) {
            return (int) hexdec($matches[1]);
        }

        return null;
    }

    /**
     * @param  array<int, int>  $colours
     */
    private function listColours(array $colours): string
    {
        $shown = array_slice(array_values($colours), 0, 6);
        $hex = implode(', ', array_map(RegionImage::hex(...), $shown));

        return count($colours) > count($shown)
            ? $hex.', …'
            : $hex;
    }

    /**
     * @param  array<string, mixed>  $page
     */
    private function artifactsFor(string $directory, string $bookUid, int $position, array $page): ?PageArtifacts
    {
        $display = $page['display'] ?? null;
        $idmap = $page['idmap'] ?? null;
        $regions = $page['regions'] ?? null;

        if (! is_string($display) || ! is_string($idmap) || ! is_string($regions)) {
            return null;
        }

        $index = is_int($page['page_index'] ?? null) ? $page['page_index'] : $position;

        /** @var mixed $size */
        $size = $page['image_size'] ?? null;
        $declaredSize = is_array($size) && is_int($size[0] ?? null) && is_int($size[1] ?? null)
            ? [$size[0], $size[1]]
            : null;

        $count = $page['region_count'] ?? null;

        return new PageArtifacts(
            sprintf('%s page %d', $bookUid, $index),
            $this->absolute($directory, $display),
            $this->absolute($directory, $idmap),
            $this->absolute($directory, $regions),
            $declaredSize,
            is_int($count) ? $count : null,
        );
    }

    private function absolute(string $directory, string $path): string
    {
        return rtrim($directory, '/\\').DIRECTORY_SEPARATOR.str_replace('/', DIRECTORY_SEPARATOR, $path);
    }
}
