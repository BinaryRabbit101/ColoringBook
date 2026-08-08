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
 *
 * ## Animated stickers (BL-38)
 *
 * An animated sticker is one sprite-sheet PNG carrying `hframes * vframes`
 * cells, so every size check above moves **onto the frame**: a 4×2 sheet of
 * 256 px frames is a 1024×512 file in which every frame is exactly right, and
 * checking the file against `sticker_max_px` would refuse it for being the
 * shape a sprite sheet is. The sheet gets its own roomier ceiling instead, and
 * two new checks join: the grid has to divide the sheet evenly (a half-pixel
 * column is a frame with a sliver of its neighbour in it, and the game slices
 * by `hframes`/`vframes` without looking), and `frames` cannot exceed the cells
 * there are to hold them.
 */
class StickerValidation
{
    /**
     * Every problem with one sticker image, in the operator's language.
     *
     * `$anim` is the sprite-sheet grid, or null for a still sticker.
     *
     * @param  string  $path  an absolute path to the image
     * @param  array{hframes: int, vframes: int, frames: int, fps: float}|null  $anim
     */
    public function validateFile(string $path, ?array $anim = null): PackValidationResult
    {
        RegionImage::assertSupported();

        if (! is_file($path)) {
            return PackValidationResult::failed([__('the image is not on disk.')]);
        }

        $bytes = @file_get_contents($path);

        if ($bytes === false) {
            return PackValidationResult::failed([__('the image could not be read.')]);
        }

        return $this->validateBytes($bytes, $anim);
    }

    /**
     * @param  array{hframes: int, vframes: int, frames: int, fps: float}|null  $anim
     */
    public function validateBytes(string $bytes, ?array $anim = null): PackValidationResult
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

        $errors = $anim === null
            ? $this->checkStill($width, $height)
            : $this->checkSheet($width, $height, $anim);

        $warnings = [];

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
     * One drawing, one file: the size bounds as BL-37 wrote them.
     *
     * @return list<string>
     */
    private function checkStill(int $width, int $height): array
    {
        $minimum = (int) config('coloringbook.admin.sticker_min_px');
        $maximum = (int) config('coloringbook.admin.sticker_max_px');

        $errors = [];

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

        return $errors;
    }

    /**
     * A sprite sheet (BL-38): the grid divides the file, the frames fit in the
     * cells, and ONE FRAME is the thing measured against the size bounds.
     *
     * @param  array{hframes: int, vframes: int, frames: int, fps: float}  $anim
     * @return list<string>
     */
    private function checkSheet(int $width, int $height, array $anim): array
    {
        $errors = [];
        $sheetMax = (int) config('coloringbook.admin.sticker_sheet_max_px');

        if ($width > $sheetMax || $height > $sheetMax) {
            $errors[] = __('the sheet is :wx:h, over the :max px ceiling for a sprite sheet.', [
                'w' => $width, 'h' => $height, 'max' => $sheetMax,
            ]);
        }

        if ($width % $anim['hframes'] !== 0 || $height % $anim['vframes'] !== 0) {
            // The game slices by hframes/vframes without looking, so a grid
            // that does not divide the sheet puts a sliver of the next frame
            // down the edge of every one of them.
            $errors[] = __('the sheet is :wx:h, which a :colsx:rows grid does not divide evenly — every frame would carry a sliver of the next one.', [
                'w' => $width, 'h' => $height, 'cols' => $anim['hframes'], 'rows' => $anim['vframes'],
            ]);

            return $errors;
        }

        if ($anim['frames'] > $anim['hframes'] * $anim['vframes']) {
            $errors[] = __('it says :frames frames but a :colsx:rows sheet only holds :cells.', [
                'frames' => $anim['frames'],
                'cols' => $anim['hframes'],
                'rows' => $anim['vframes'],
                'cells' => $anim['hframes'] * $anim['vframes'],
            ]);
        }

        return [
            ...$errors,
            ...$this->checkStill(
                intdiv($width, $anim['hframes']),
                intdiv($height, $anim['vframes']),
            ),
        ];
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
                    $this->prefix(
                        // BL-38: an entry carrying `anim` is a sprite sheet, and
                        // the size bounds are measured on one frame of it.
                        $this->validateFile($absolute, StickerAnim::of($sticker)),
                        sprintf('%s / %s', $uid, $id),
                    ),
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
