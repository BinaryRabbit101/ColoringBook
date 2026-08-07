<?php

namespace App\Services;

/**
 * What the server checks about a sticker (BL-37) — `PackValidation`'s much
 * smaller sibling.
 *
 * §10.1's decision was that the server validates the mapping pipeline's OUTPUT
 * rather than running it, and everything expensive in `PackValidation` is about
 * a page's ID map: the dimensions agreeing, the JSON-ids ↔ idmap-colours
 * bijection, the giant region. **A sticker has none of that.** It has no
 * regions, no ID map and no regions JSON, so the publish gate is image checks
 * only, and the sticker publish path is genuinely simpler than a book's rather
 * than pretending to be.
 *
 * What is worth checking, and why each one is here:
 *
 * 1. **It decodes.** A file the operator uploaded that GD cannot read would
 *    reach a child's device as a sticker card with nothing on it.
 * 2. **It is not tiny and not enormous.** A sticker is drawn at ~17 % of a
 *    page's short side (BL-36), so under `min_px` it is a blurred smudge on a
 *    2048 px page; over `max_px` it is megabytes of texture for a shape a
 *    thumb covers.
 * 3. **It has transparency to spare.** A sticker is a CUT-OUT laid over a
 *    drawing; a fully opaque rectangle would paste a white box over the child's
 *    colouring. This is a WARNING, not an error — a deliberately square sticker
 *    is legal, just unusual, and the operator is looking at a preview.
 * 4. **Something is actually drawn.** A fully transparent image is an export
 *    that went wrong, and it is an error: there is nothing to stick down.
 */
class StickerValidation
{
    /**
     * Every problem with one sticker image, in the operator's language.
     *
     * @param  string  $path  an absolute path to the image
     */
    public function validateFile(string $path): PackValidationResult
    {
        RegionImage::assertSupported();

        if (! is_file($path)) {
            return PackValidationResult::failed([__('the image is not on disk.')]);
        }

        $bytes = @file_get_contents($path);

        if ($bytes === false) {
            return PackValidationResult::failed([__('the image could not be read.')]);
        }

        return $this->validateBytes($bytes);
    }

    public function validateBytes(string $bytes): PackValidationResult
    {
        RegionImage::assertSupported();

        $image = @imagecreatefromstring($bytes);

        if ($image === false) {
            return PackValidationResult::failed([
                __('this is not an image any browser or the game could open.'),
            ]);
        }

        $width = imagesx($image);
        $height = imagesy($image);
        $minimum = (int) config('coloringbook.admin.sticker_min_px');
        $maximum = (int) config('coloringbook.admin.sticker_max_px');

        $errors = [];
        $warnings = [];

        if ($width < $minimum || $height < $minimum) {
            $errors[] = __('it is :wx:h, and a sticker must be at least :min px on both sides — smaller than that it is a smudge on a 2048 px page.', [
                'w' => $width, 'h' => $height, 'min' => $minimum,
            ]);
        }

        if ($width > $maximum || $height > $maximum) {
            $errors[] = __('it is :wx:h, over the :max px ceiling for a sticker.', [
                'w' => $width, 'h' => $height, 'max' => $maximum,
            ]);
        }

        if ($errors === []) {
            $alpha = $this->alphaProfile($image, $width, $height);

            if ($alpha['opaque'] === 0) {
                $errors[] = __('every pixel of it is transparent — there is nothing to stick down.');
            } elseif ($alpha['transparent'] === 0) {
                $warnings[] = __('it has no transparent pixels at all, so it will paste a solid rectangle over the drawing. A sticker is normally a cut-out shape.');
            }
        }

        imagedestroy($image);

        return new PackValidationResult($errors, $warnings);
    }

    /**
     * How many sampled pixels are fully transparent and how many are not.
     *
     * Sampled on a grid rather than read pixel by pixel: a 1024² sticker is a
     * million `imagecolorat()` calls for a question a few thousand answer just
     * as well, and this runs on every upload.
     *
     * @return array{transparent: int, opaque: int}
     */
    private function alphaProfile(\GdImage $image, int $width, int $height): array
    {
        $step = max(1, (int) floor(max($width, $height) / 64));
        $transparent = 0;
        $opaque = 0;

        for ($y = 0; $y < $height; $y += $step) {
            for ($x = 0; $x < $width; $x += $step) {
                // GD packs alpha 0..127 into bits 24-30, where 127 is invisible.
                $alpha = (imagecolorat($image, $x, $y) >> 24) & 0x7F;

                if ($alpha >= 127) {
                    $transparent++;
                } else {
                    $opaque++;
                }
            }
        }

        return ['transparent' => $transparent, 'opaque' => $opaque];
    }

    /**
     * Every sticker in a built pack directory (BL-37) — the sticker-pack
     * counterpart of `PackValidation::validate()`, and what `SubmitPackVersion`
     * runs in its place.
     *
     * Stickers whose files are missing are skipped in silence:
     * `PackManifestValidator` reports those, and saying it twice in one
     * `errors[]` list helps nobody.
     */
    public function validate(PackManifest $manifest, string $directory): PackValidationResult
    {
        $result = new PackValidationResult;

        foreach ($manifest->stickerSets() as $index => $set) {
            $uid = is_string($set['set_uid'] ?? null) && trim($set['set_uid']) !== ''
                ? trim($set['set_uid'])
                : sprintf('sticker_sets[%d]', $index);

            foreach (PackManifest::stickersOf($set) as $position => $sticker) {
                $image = $sticker['image'] ?? null;

                if (! is_string($image) || $image === '') {
                    continue;
                }

                $absolute = rtrim($directory, '/\\').DIRECTORY_SEPARATOR
                    .str_replace('/', DIRECTORY_SEPARATOR, $image);

                if (! is_file($absolute)) {
                    continue;
                }

                $id = is_string($sticker['sticker_id'] ?? null) && trim($sticker['sticker_id']) !== ''
                    ? trim($sticker['sticker_id'])
                    : (string) $position;

                $result = $result->merge(
                    $this->prefix($this->validateFile($absolute), sprintf('%s / %s', $uid, $id)),
                );
            }
        }

        return $result;
    }

    private function prefix(PackValidationResult $result, string $label): PackValidationResult
    {
        $decorate = fn (string $message): string => sprintf('%s: %s', $label, $message);

        return new PackValidationResult(
            array_map($decorate, $result->errors),
            array_map($decorate, $result->warnings),
        );
    }
}
