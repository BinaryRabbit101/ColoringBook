<?php

namespace App\Actions\Authoring;

use App\Models\AuthoredStickerSet;
use App\Models\Pack;
use App\Models\Sticker;
use App\Models\StickerSet;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;

/**
 * `DELETE /admin/sticker-sets/{set_uid}` — BL-24's one non-obvious rule,
 * applied to stickers (BL-37, §7.3).
 *
 * **Never published → deleted outright.** Nobody owns it, nobody has downloaded
 * it, and leaving a dead slug behind would reserve a `set_uid` for a mistake
 * forever.
 *
 * **Published → the pack is RETIRED**, and only the authoring workspace goes.
 * `Pack::scopeDownloadable()` includes `retired`, so delisting never takes a
 * sticker set off a device that has it — and it must not, because stickers a
 * child has already stuck on a page name that set and would otherwise disappear
 * from drawings that are already finished.
 *
 * Assets are never deleted either way: they are shared by digest and a published
 * release may be standing on the same bytes.
 */
class DeleteAuthoredStickerSet
{
    public const DELETED = 'deleted';

    public const RETIRED = 'retired';

    /**
     * @return self::DELETED|self::RETIRED what actually happened to the pack
     */
    public function handle(AuthoredStickerSet $set): string
    {
        $pack = $set->pack;
        $everPublished = $pack->versions()->whereNotNull('published_at')->exists();
        $slug = $pack->slug;

        DB::transaction(function () use ($set, $pack, $everPublished): void {
            $set->stickers()->delete();
            $set->delete();

            if ($everPublished) {
                $pack->status = Pack::STATUS_RETIRED;
                $pack->save();

                return;
            }

            /** @var array<int, int> $setIds */
            $setIds = $pack->stickerSets()->pluck('id')->all();

            if ($setIds !== []) {
                Sticker::query()->whereIn('sticker_set_id', $setIds)->delete();
                StickerSet::query()->whereIn('id', $setIds)->delete();
            }

            $pack->entitlements()->delete();
            $pack->versions()->delete();
            $pack->delete();
        });

        if (! $everPublished) {
            // Rows first, bytes second — a disk cannot be rolled back.
            Storage::disk((string) config('coloringbook.storage.packs_disk'))->deleteDirectory($slug);
        }

        return $everPublished ? self::RETIRED : self::DELETED;
    }
}
