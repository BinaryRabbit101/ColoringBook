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

    public function handle(
        AuthoredStickerSet $set,
        Asset $image,
        string $stickerId,
        ?string $title = null,
    ): AuthoredSticker {
        return DB::transaction(function () use ($set, $image, $stickerId, $title): AuthoredSticker {
            $next = (int) ($set->stickers()->max('sticker_index') ?? -1) + 1;

            /** @var AuthoredSticker $sticker */
            $sticker = $set->stickers()->create([
                'sticker_index' => $next,
                'sticker_id' => $stickerId,
                'title' => $title,
                'image_asset_id' => $image->id,
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
     */
    public function revalidate(AuthoredSticker $sticker, Asset $image): void
    {
        $disk = Storage::disk((string) config('coloringbook.storage.assets_disk'));
        $bytes = $disk->exists($image->storage_path) ? $disk->get($image->storage_path) : null;

        $result = $bytes === null
            ? PackValidationResult::failed([__('the image is no longer on disk — upload it again.')])
            : $this->validation->validateBytes($bytes);

        $sticker->forceFill([
            'image_asset_id' => $image->id,
            'image_w' => $image->width,
            'image_h' => $image->height,
            'validation_errors' => $result->errors,
            'validation_warnings' => $result->warnings,
        ])->save();
    }
}
