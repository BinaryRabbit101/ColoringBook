<?php

namespace App\Actions\Authoring;

use App\Models\Asset;
use App\Models\AuthoredSticker;
use App\Models\AuthoredStickerSet;
use App\Services\PackValidationResult;
use App\Services\StickerValidation;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;

/**
 * `POST /admin/sticker-sets/{set_uid}/stickers` — add a sticker (BL-37).
 *
 * A sticker needs two things: a stable `sticker_id` and one image. There is no
 * mapping job, no queue and no derived artifacts — §10.3 said the sticker
 * publish path would be strictly simpler than a book's, and this is where that
 * is cashed in: the image is validated **inline, on the way in**, and the
 * verdict is stored on the row.
 *
 * The sticker is appended at the end. Reordering is `UpdateAuthoredSticker`'s
 * job, for the reason `StoreAuthoredPage` gives — one mechanism that renumbers a
 * set is easier to trust than two.
 */
class StoreAuthoredSticker
{
    public function __construct(private readonly StickerValidation $validation) {}

    /**
     * BL-38: `$anim` is the sprite-sheet grid when this sticker is animated.
     * Null — not an empty object — is what "still drawing" means, all the way
     * to the manifest.
     *
     * @param  array{hframes: int, vframes: int, frames: int, fps: float}|null  $anim
     */
    public function handle(
        AuthoredStickerSet $set,
        Asset $image,
        string $stickerId,
        ?string $title = null,
        ?array $anim = null,
    ): AuthoredSticker {
        return DB::transaction(function () use ($set, $image, $stickerId, $title, $anim): AuthoredSticker {
            $next = (int) ($set->stickers()->max('sticker_index') ?? -1) + 1;

            /** @var AuthoredSticker $sticker */
            $sticker = $set->stickers()->create([
                'sticker_index' => $next,
                'sticker_id' => $stickerId,
                'title' => $title,
                'image_asset_id' => $image->id,
                'anim' => $anim,
            ]);

            $this->revalidate($sticker, $image);

            return $sticker;
        });
    }

    /**
     * Reads the stored bytes back and records what `StickerValidation` made of
     * them. Called on creation and on every art replacement, so a row's verdict
     * always describes the image it is actually pointing at.
     *
     * Shared with `UpdateAuthoredSticker` rather than duplicated: "the verdict
     * matches the art" is exactly the invariant that decays when there are two
     * copies of the code that maintains it.
     *
     * The verdict is read against the row's **current** `anim`, so changing the
     * grid on a sheet that is already uploaded re-checks the sheet against the
     * new grid — which is where "4×2 does not divide a 300 px-wide sheet" is
     * actually noticed.
     */
    public function revalidate(AuthoredSticker $sticker, Asset $image): void
    {
        $disk = Storage::disk((string) config('coloringbook.storage.assets_disk'));
        $bytes = $disk->exists($image->storage_path) ? $disk->get($image->storage_path) : null;

        $result = $bytes === null
            ? PackValidationResult::failed([__('the image is no longer on disk — upload it again.')])
            : $this->validation->validateBytes($bytes, $sticker->anim);

        $sticker->forceFill([
            'image_asset_id' => $image->id,
            'image_w' => $image->width,
            'image_h' => $image->height,
            'validation_errors' => $result->errors,
            'validation_warnings' => $result->warnings,
        ])->save();
    }
}
