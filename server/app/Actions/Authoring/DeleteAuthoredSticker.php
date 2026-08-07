<?php

namespace App\Actions\Authoring;

use App\Models\AuthoredSticker;
use Illuminate\Support\Facades\DB;

/**
 * `DELETE /admin/sticker-sets/{set_uid}/stickers/{index}` — remove a sticker and
 * close the gap (BL-37).
 *
 * Renumbering matters less here than it does for pages — a client resolves a
 * saved placement by `sticker_id`, never by index (BL-36), so a hole would not
 * corrupt anybody's drawing. It is still done, because `sticker_index` is what
 * decides the order of the cards on the strip and a gap would put a silent
 * blank between two of them.
 *
 * The sticker's **asset is left alone**, deliberately: assets are content-
 * addressed and shared by digest, and a published release may be standing on
 * those exact bytes.
 */
class DeleteAuthoredSticker
{
    public function handle(AuthoredSticker $sticker): void
    {
        DB::transaction(function () use ($sticker): void {
            $set = $sticker->set;
            $sticker->delete();

            /** @var list<AuthoredSticker> $remaining */
            $remaining = $set->stickers()->get()->all();

            foreach ($remaining as $position => $candidate) {
                if ($candidate->sticker_index !== $position) {
                    $candidate->forceFill(['sticker_index' => $position])->save();
                }
            }
        });
    }
}
