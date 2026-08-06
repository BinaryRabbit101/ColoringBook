<?php

namespace App\Services;

use App\Exceptions\ApiException;
use App\Models\PackVersion;
use GdImage;
use Illuminate\Contracts\Filesystem\Filesystem;
use Illuminate\Support\Facades\Storage;
use Symfony\Component\HttpFoundation\Response;

/**
 * "The same debug overlay the game has, in the browser" (DLC_SERVER.md §10.1).
 *
 * The reviewer's question about a new pack is never "does the manifest parse".
 * It is *did this page map to the shapes I drew* — and the only honest answer
 * is a picture. So this composites each region of the ID map as a flat tint
 * under the display art, which is exactly what the in-game region-debug
 * overlay does, and hands it to the admin UI as a PNG.
 *
 * Three things make it correct rather than merely pretty:
 *
 * - **Tints are random-but-stable.** The colour is derived from the region's
 *   own ID-map colour, so page 1 looks the same on every reload and two
 *   adjacent regions that the artist thinks are one shape are visibly two.
 *   A palette would be prettier and would hide exactly the failure being
 *   looked for.
 * - **The ID map is downscaled nearest-neighbour**, never resampled. A
 *   smooth resample averages neighbouring region ids and invents colours that
 *   belong to no region at all; the display art, which has no semantics in its
 *   pixels, is resampled properly.
 * - **`#000000` is left alone.** Line work is unpaintable, so it shows through
 *   as the artist drew it and the tinted areas are precisely the paintable
 *   ones.
 *
 * Renders are cached beside the release's other artifacts
 * (`<slug>/v<N>/previews/…`), because a 2048² composite in PHP is a second or
 * two and a reviewer flips back and forth.
 */
class PackPreview
{
    /**
     * Every page in a release, in book-then-page order — what the admin UI
     * builds its page picker from.
     *
     * @return list<array{book_uid: string, book_title: string, page_index: int, title: string|null, image_size: array{0: int, 1: int}|null, region_count: int|null}>
     */
    public function pages(PackVersion $version): array
    {
        $manifest = new PackManifest($version->manifest);
        $pages = [];

        foreach ($manifest->books() as $book) {
            $uid = is_string($book['book_uid'] ?? null) ? trim($book['book_uid']) : '';
            $bookTitle = is_string($book['title'] ?? null) ? $book['title'] : $uid;

            foreach (PackManifest::pagesOf($book) as $position => $page) {
                /** @var mixed $size */
                $size = $page['image_size'] ?? null;
                $title = $page['title'] ?? null;
                $count = $page['region_count'] ?? null;

                $pages[] = [
                    'book_uid' => $uid,
                    'book_title' => $bookTitle,
                    'page_index' => is_int($page['page_index'] ?? null) ? $page['page_index'] : $position,
                    'title' => is_string($title) ? $title : null,
                    'image_size' => is_array($size) && is_int($size[0] ?? null) && is_int($size[1] ?? null)
                        ? [$size[0], $size[1]]
                        : null,
                    'region_count' => is_int($count) ? $count : null,
                ];
            }
        }

        return $pages;
    }

    /**
     * The composited overlay for one page, as PNG bytes.
     */
    public function render(PackVersion $version, string $bookUid, int $pageIndex): string
    {
        RegionImage::assertSupported();

        $disk = Storage::disk((string) config('coloringbook.storage.packs_disk'));
        $slug = $version->pack->slug;
        $base = PackVersion::directoryFor($slug, $version->version);
        $cached = sprintf('%s/previews/%s/page_%d.png', $base, $this->safeSegment($bookUid), $pageIndex);

        if ($disk->exists($cached)) {
            return (string) $disk->get($cached);
        }

        [$displayPath, $idmapPath] = $this->artifactPaths($version, $bookUid, $pageIndex);

        $display = $this->load($disk, $base.'/files/'.$displayPath);
        $idmap = $this->load($disk, $base.'/files/'.$idmapPath);

        try {
            $png = $this->composite($display, $idmap);
        } finally {
            $display->destroy();
            $idmap->destroy();
        }

        $disk->put($cached, $png);

        return $png;
    }

    /**
     * @return array{0: string, 1: string} display path, ID-map path — both
     *                                     pack-relative
     */
    private function artifactPaths(PackVersion $version, string $bookUid, int $pageIndex): array
    {
        $manifest = new PackManifest($version->manifest);

        foreach ($manifest->books() as $book) {
            if (! is_string($book['book_uid'] ?? null) || trim($book['book_uid']) !== $bookUid) {
                continue;
            }

            foreach (PackManifest::pagesOf($book) as $position => $page) {
                $index = is_int($page['page_index'] ?? null) ? $page['page_index'] : $position;

                if ($index !== $pageIndex) {
                    continue;
                }

                $display = $page['display'] ?? null;
                $idmap = $page['idmap'] ?? null;

                if (is_string($display) && is_string($idmap)) {
                    return [$display, $idmap];
                }
            }
        }

        throw new ApiException(
            'PREVIEW_PAGE_NOT_FOUND',
            __('That page is not part of this pack version.'),
            Response::HTTP_NOT_FOUND,
        );
    }

    private function load(Filesystem $disk, string $path): RegionImage
    {
        $bytes = $disk->exists($path) ? $disk->get($path) : null;
        $image = is_string($bytes) ? RegionImage::fromBytes($bytes) : null;

        if ($image === null) {
            throw new ApiException(
                'FILE_NOT_FOUND',
                __('That page artwork is no longer on disk.'),
                Response::HTTP_NOT_FOUND,
            );
        }

        return $image;
    }

    /**
     * Tint every region of `$idmap` under `$display`, at preview resolution.
     */
    private function composite(RegionImage $display, RegionImage $idmap): string
    {
        [$width, $height] = $this->previewSize($display->width, $display->height);

        $art = imagecreatetruecolor($width, $height);
        imagealphablending($art, false);
        imagesavealpha($art, false);
        imagecopyresampled($art, $display->gd(), 0, 0, 0, 0, $width, $height, $display->width, $display->height);

        // Nearest neighbour: a resampled ID map invents region ids.
        $ids = imagecreatetruecolor($width, $height);
        imagealphablending($ids, false);
        imagesavealpha($ids, false);
        imagecopyresized($ids, $idmap->gd(), 0, 0, 0, 0, $width, $height, $idmap->width, $idmap->height);

        $alpha = (float) config('coloringbook.admin.preview_tint_alpha');
        $tints = [];

        try {
            for ($y = 0; $y < $height; $y++) {
                for ($x = 0; $x < $width; $x++) {
                    $id = imagecolorat($ids, $x, $y) & 0xFFFFFF;

                    if ($id === RegionImage::LINE_COLOUR) {
                        continue;
                    }

                    $tint = $tints[$id] ??= $this->tintFor($id);
                    $under = imagecolorat($art, $x, $y) & 0xFFFFFF;

                    imagesetpixel($art, $x, $y, $this->blend($under, $tint, $alpha));
                }
            }

            return $this->encode($art);
        } finally {
            imagedestroy($ids);
            imagedestroy($art);
        }
    }

    /**
     * Fit the composite inside `coloringbook.admin.preview_max_px` on its long
     * edge. A shipped page is up to 2048² and a per-pixel loop in PHP is not
     * free; the reviewer is looking for "did this shape come out as one
     * region", which survives the downscale.
     *
     * @return array{0: int<1, max>, 1: int<1, max>}
     */
    private function previewSize(int $width, int $height): array
    {
        $max = (int) config('coloringbook.admin.preview_max_px');
        $longest = max($width, $height);

        if ($max < 1 || $longest <= $max) {
            return [max(1, $width), max(1, $height)];
        }

        $scale = $max / $longest;

        return [max(1, (int) round($width * $scale)), max(1, (int) round($height * $scale))];
    }

    /**
     * A stable, well-spread colour for a region id.
     *
     * The hue comes from a hash of the id rather than from the id itself: the
     * pipeline numbers regions 1, 2, 3 …, so using the id directly would give
     * every page the same near-black gradient and adjacent regions would be
     * indistinguishable — the exact thing the overlay exists to show.
     */
    private function tintFor(int $id): int
    {
        $hash = crc32(RegionImage::hex($id));

        return $this->hsvToRgb(
            ($hash % 360) / 360,
            0.62 + (($hash >> 9) % 24) / 100,
            0.78 + (($hash >> 17) % 18) / 100,
        );
    }

    private function blend(int $under, int $tint, float $alpha): int
    {
        $mix = static fn (int $a, int $b): int => (int) round($a * (1 - $alpha) + $b * $alpha);

        return ($mix(($under >> 16) & 0xFF, ($tint >> 16) & 0xFF) << 16)
            | ($mix(($under >> 8) & 0xFF, ($tint >> 8) & 0xFF) << 8)
            | $mix($under & 0xFF, $tint & 0xFF);
    }

    private function hsvToRgb(float $h, float $s, float $v): int
    {
        $s = min(1.0, max(0.0, $s));
        $v = min(1.0, max(0.0, $v));

        $i = (int) floor($h * 6);
        $f = $h * 6 - $i;
        $p = $v * (1 - $s);
        $q = $v * (1 - $f * $s);
        $t = $v * (1 - (1 - $f) * $s);

        [$r, $g, $b] = match ($i % 6) {
            0 => [$v, $t, $p],
            1 => [$q, $v, $p],
            2 => [$p, $v, $t],
            3 => [$p, $q, $v],
            4 => [$t, $p, $v],
            default => [$v, $p, $q],
        };

        return ((int) round($r * 255) << 16) | ((int) round($g * 255) << 8) | (int) round($b * 255);
    }

    private function encode(GdImage $image): string
    {
        ob_start();
        imagepng($image, null, 6);

        return (string) ob_get_clean();
    }

    /**
     * A `book_uid` is already slug-shaped by the time it is published, but the
     * cache path is a filesystem path and this is the last place to be sure.
     */
    private function safeSegment(string $value): string
    {
        $safe = preg_replace('/[^A-Za-z0-9._-]/', '_', $value);

        return $safe === null || $safe === '' ? 'book' : $safe;
    }
}
