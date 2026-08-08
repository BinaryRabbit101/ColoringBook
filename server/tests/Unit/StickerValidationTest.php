<?php

namespace Tests\Unit;

use App\Services\StickerValidation;
use Tests\Concerns\AuthorsStickerSets;
use Tests\TestCase;

/**
 * BL-37 — what the server checks about a sticker image, and what it
 * deliberately does not.
 *
 * Each case asserts both that the right problem was found **and** that nothing
 * else was, the same discipline `PackValidationTest` follows: a validator that
 * reports four things when one is wrong is a validator nobody reads.
 */
class StickerValidationTest extends TestCase
{
    use AuthorsStickerSets;

    private StickerValidation $validation;

    protected function setUp(): void
    {
        parent::setUp();

        $this->validation = new StickerValidation;
    }

    public function test_a_real_sticker_passes_clean(): void
    {
        $result = $this->validation->validateFile($this->stickerFixturePath('star.png'));

        $this->assertSame([], $result->errors);
        $this->assertSame([], $result->warnings);
        $this->assertTrue($result->passed());
    }

    public function test_bytes_that_are_not_an_image_are_refused(): void
    {
        $result = $this->validation->validateBytes('not a png, not anything');

        $this->assertCount(1, $result->errors);
        $this->assertStringContainsString('not an image', $result->errors[0]);
    }

    public function test_a_missing_file_is_reported_rather_than_thrown(): void
    {
        $result = $this->validation->validateFile($this->stickerFixturePath('nope.png'));

        $this->assertCount(1, $result->errors);
        $this->assertStringContainsString('not on disk', $result->errors[0]);
    }

    public function test_a_sticker_under_the_floor_is_refused(): void
    {
        $result = $this->validation->validateBytes($this->png(8, 8, opaque: true));

        $this->assertCount(1, $result->errors);
        $this->assertStringContainsString('at least', $result->errors[0]);
    }

    public function test_a_sticker_over_the_ceiling_is_refused(): void
    {
        $maximum = (int) config('coloringbook.admin.sticker_max_px');

        $result = $this->validation->validateBytes($this->png($maximum + 8, 64, opaque: true));

        $this->assertCount(1, $result->errors);
        $this->assertStringContainsString('ceiling', $result->errors[0]);
    }

    public function test_a_fully_transparent_sticker_is_an_error(): void
    {
        $result = $this->validation->validateBytes($this->png(64, 64, opaque: false));

        $this->assertCount(1, $result->errors);
        $this->assertStringContainsString('nothing to stick down', $result->errors[0]);
    }

    /**
     * A solid rectangle is legal — a deliberately square sticker exists — but it
     * will paste a box over a child's drawing, so it is a WARNING and the
     * operator decides. Warnings never block a publish.
     */
    public function test_a_sticker_with_no_transparency_at_all_is_only_a_warning(): void
    {
        $result = $this->validation->validateBytes($this->png(64, 64, opaque: true));

        $this->assertSame([], $result->errors);
        $this->assertCount(1, $result->warnings);
        $this->assertStringContainsString('cut-out', $result->warnings[0]);
        $this->assertTrue($result->passed());
    }

    // ------------------------------------------------------------ BL-38 ---

    /**
     * The whole reason the animated path exists: a 4x2 sheet of 64 px frames is
     * a 256x128 file, which the still checks would refuse for being 128 px tall
     * against a 64 px floor in one direction and… no, they would pass it — and
     * a 16x8 sheet of the same frames is 1024x512, which they would refuse for
     * being over the 1024 ceiling in width while every frame in it is exactly
     * the right size. The bounds have to move onto the frame.
     */
    public function test_a_sprite_sheet_is_measured_by_its_frames(): void
    {
        $sheet = $this->png(1024, 512, opaque: true);
        $anim = ['hframes' => 16, 'vframes' => 8, 'frames' => 128, 'fps' => 12.0];

        $this->assertSame([], $this->validation->validateBytes($sheet, $anim)->errors);
    }

    public function test_a_sheet_whose_frames_are_under_the_floor_is_refused(): void
    {
        // 256x128 in a 16x8 grid is 16 px frames: a smudge on a 2048 px page.
        $result = $this->validation->validateBytes(
            $this->png(256, 128, opaque: true),
            ['hframes' => 16, 'vframes' => 8, 'frames' => 128, 'fps' => 12.0],
        );

        $this->assertCount(1, $result->errors);
        $this->assertStringContainsString('at least', $result->errors[0]);
    }

    public function test_a_grid_that_does_not_divide_the_sheet_is_refused_alone(): void
    {
        $result = $this->validation->validateBytes(
            $this->png(300, 100, opaque: true),
            ['hframes' => 7, 'vframes' => 1, 'frames' => 7, 'fps' => 10.0],
        );

        // Exactly one problem: with the grid wrong, "the frames are 42 px" is
        // noise about a frame nobody drew.
        $this->assertCount(1, $result->errors);
        $this->assertStringContainsString('does not divide evenly', $result->errors[0]);
    }

    public function test_more_frames_than_cells_is_refused(): void
    {
        $result = $this->validation->validateBytes(
            $this->png(128, 128, opaque: true),
            ['hframes' => 2, 'vframes' => 2, 'frames' => 9, 'fps' => 10.0],
        );

        $this->assertCount(1, $result->errors);
        $this->assertStringContainsString('only holds 4', $result->errors[0]);
    }

    public function test_a_sheet_over_the_sheet_ceiling_is_refused(): void
    {
        $ceiling = (int) config('coloringbook.admin.sticker_sheet_max_px');

        config(['coloringbook.admin.sticker_sheet_max_px' => 256]);

        $result = $this->validation->validateBytes(
            $this->png(512, 128, opaque: true),
            ['hframes' => 4, 'vframes' => 1, 'frames' => 4, 'fps' => 10.0],
        );

        config(['coloringbook.admin.sticker_sheet_max_px' => $ceiling]);

        $this->assertCount(1, $result->errors);
        $this->assertStringContainsString('sprite sheet', $result->errors[0]);
    }

    /**
     * A PNG of `$width` x `$height`, either wholly opaque or wholly clear.
     */
    private function png(int $width, int $height, bool $opaque): string
    {
        $image = imagecreatetruecolor($width, $height);
        imagesavealpha($image, true);
        imagealphablending($image, false);
        imagefilledrectangle(
            $image, 0, 0, $width - 1, $height - 1,
            (int) imagecolorallocatealpha($image, 220, 90, 90, $opaque ? 0 : 127),
        );

        ob_start();
        imagepng($image);
        $bytes = (string) ob_get_clean();
        imagedestroy($image);

        return $bytes;
    }
}
