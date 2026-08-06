<?php

namespace App\Services;

use GdImage;
use RuntimeException;

/**
 * A raster we are about to read region colours out of — an ID map, or the
 * display art it belongs to.
 *
 * Two jobs, both of which are easy to get subtly wrong with bare GD:
 *
 * 1. **Always truecolour.** A PNG written by an optimiser (or by Godot's own
 *    exporter on a small palette) can come back as a palette image, and
 *    `imagecolorat()` then returns a *palette index*, not an RGB triple. An
 *    ID map read that way looks like it has ids 0, 1, 2 … and every §10.1
 *    check downstream is nonsense. `imagepalettetotruecolor()` on the way in
 *    makes the rest of the code able to assume RGB.
 * 2. **Alpha is not part of a region id.** `id = R<<16 | G<<8 | B`
 *    (mapping-pipeline skill), so the alpha byte GD packs into the high bits
 *    is masked off everywhere.
 *
 * GD rather than Imagick because it is the extension that is actually present
 * on the box, and because none of this needs more than "give me the pixels".
 */
class RegionImage
{
    /** `#000000` is reserved for line work and is never a paintable region. */
    public const LINE_COLOUR = 0x000000;

    private function __construct(
        private readonly GdImage $image,
        public readonly int $width,
        public readonly int $height,
    ) {}

    /**
     * Fail loudly and early rather than producing empty region maps: without
     * GD there is no §10.1 validation and no preview, and silently passing
     * every pack would be far worse than a 500.
     */
    public static function assertSupported(): void
    {
        if (! extension_loaded('gd') || ! function_exists('imagecreatefromstring')) {
            throw new RuntimeException(
                'The GD extension is required to validate and preview pack artwork. Enable ext-gd.',
            );
        }
    }

    public static function fromPath(string $path): ?self
    {
        if (! is_file($path)) {
            return null;
        }

        $bytes = @file_get_contents($path);

        return $bytes === false ? null : self::fromBytes($bytes);
    }

    public static function fromBytes(string $bytes): ?self
    {
        self::assertSupported();

        $image = @imagecreatefromstring($bytes);

        if ($image === false) {
            return null;
        }

        if (! imageistruecolor($image)) {
            imagepalettetotruecolor($image);
        }

        return new self($image, imagesx($image), imagesy($image));
    }

    /**
     * Every distinct RGB in the image and how many pixels wear it.
     *
     * This is the one expensive operation in the package — a full scan — so
     * it is memoised nowhere and called once per image per check on purpose:
     * the caller decides how many times it pays for it.
     *
     * @return array<int, int> RGB → pixel count
     */
    public function colourCounts(): array
    {
        $counts = [];

        for ($y = 0; $y < $this->height; $y++) {
            for ($x = 0; $x < $this->width; $x++) {
                $rgb = imagecolorat($this->image, $x, $y) & 0xFFFFFF;
                $counts[$rgb] = ($counts[$rgb] ?? 0) + 1;
            }
        }

        return $counts;
    }

    public function colourAt(int $x, int $y): int
    {
        return imagecolorat($this->image, $x, $y) & 0xFFFFFF;
    }

    public function gd(): GdImage
    {
        return $this->image;
    }

    public function sizeMatches(self $other): bool
    {
        return $this->width === $other->width && $this->height === $other->height;
    }

    public function destroy(): void
    {
        imagedestroy($this->image);
    }

    /**
     * `#RRGGBB`, upper case — the form every §10.1 message and every regions
     * JSON `id_color` is compared in.
     */
    public static function hex(int $rgb): string
    {
        return sprintf('#%06X', $rgb & 0xFFFFFF);
    }
}
