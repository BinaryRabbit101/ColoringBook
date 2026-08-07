<?php

namespace Tests\Concerns;

use App\Models\AuthoredSticker;
use App\Models\AuthoredStickerSet;
use Illuminate\Http\UploadedFile;

/**
 * The BL-37 fixtures, and the one thing a sticker test always needs: a real PNG
 * with alpha in it.
 *
 * There is no `fakeMapping()` counterpart here, and that absence is the point:
 * a sticker has no regions, so there is no pipeline, no queue and nothing to
 * stub. `StickerValidation` reads the bytes inline, so a sticker that came back
 * from an endpoint has really been through the whole store → validate path.
 *
 * `tests/Fixtures/packs/sticker-sheet` is a third pack beside WP3's
 * `forest-friends` and WP5's `meadow-mates`: 64×64 discs on transparent
 * backgrounds — a shape AND clear space around it, which is exactly what
 * `StickerValidation` is looking at.
 */
trait AuthorsStickerSets
{
    protected function stickerPackFixturePath(string $name = 'sticker-sheet'): string
    {
        return dirname(__DIR__).DIRECTORY_SEPARATOR.'Fixtures'
            .DIRECTORY_SEPARATOR.'packs'.DIRECTORY_SEPARATOR.$name;
    }

    protected function stickerFixturePath(string $file = 'star.png'): string
    {
        return $this->stickerPackFixturePath()
            .DIRECTORY_SEPARATOR.'stickers'
            .DIRECTORY_SEPARATOR.'sheet-stickers-2026'
            .DIRECTORY_SEPARATOR.$file;
    }

    /**
     * A real sticker PNG wrapped as an upload.
     *
     * `$test: true` keeps Symfony from rejecting it for not having come through
     * PHP's upload machinery — the same trick `AdminsPacks::packUpload()` uses.
     */
    protected function stickerUpload(string $file = 'star.png', ?string $as = null): UploadedFile
    {
        return new UploadedFile(
            $this->stickerFixturePath($file),
            $as ?? $file,
            'image/png',
            null,
            true,
        );
    }

    /**
     * A PNG that `StickerValidation` will refuse: 8×8, well under the floor.
     */
    protected function tinyStickerUpload(string $as = 'speck.png'): UploadedFile
    {
        $path = (string) tempnam(sys_get_temp_dir(), 'speck').'.png';
        $image = imagecreatetruecolor(8, 8);
        imagesavealpha($image, true);
        imagefill($image, 0, 0, (int) imagecolorallocatealpha($image, 200, 40, 40, 0));
        imagepng($image, $path);
        imagedestroy($image);

        return new UploadedFile($path, $as, 'image/png', null, true);
    }

    /**
     * A sticker set with `$stickers` valid stickers — the shape that can
     * publish. Driven through the real endpoints, so the rows are what the
     * authoring flow actually produces.
     */
    protected function authorStickerSet(
        string $setUid = 'starter-stickers-2026',
        int $stickers = 2,
        bool $free = true,
    ): AuthoredStickerSet {
        $this->postJson('/api/v1/admin/sticker-sets', [
            'set_uid' => $setUid,
            'title' => 'Starter Stickers',
            'is_free' => $free,
        ])->assertCreated();

        $names = ['star', 'heart', 'moon'];

        for ($i = 0; $i < $stickers; $i++) {
            $name = $names[$i % count($names)];

            $this->post("/api/v1/admin/sticker-sets/{$setUid}/stickers", [
                'image' => $this->stickerUpload($name.'.png'),
                'sticker_id' => $name.($i >= count($names) ? '-'.$i : ''),
                'title' => ucfirst($name),
            ])->assertCreated();
        }

        /** @var AuthoredStickerSet */
        return AuthoredStickerSet::query()->where('set_uid', $setUid)->sole();
    }

    /**
     * @return list<AuthoredSticker>
     */
    protected function stickersOf(AuthoredStickerSet $set): array
    {
        /** @var list<AuthoredSticker> */
        return $set->stickers()->get()->all();
    }
}
