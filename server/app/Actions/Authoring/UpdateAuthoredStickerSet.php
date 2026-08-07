<?php

namespace App\Actions\Authoring;

use App\Models\AuthoredStickerSet;
use Illuminate\Support\Facades\DB;

/**
 * `PATCH /admin/sticker-sets/{set_uid}` — retitle a set, or move it in the
 * client's cycle ring (BL-37).
 *
 * Title and blurb are mirrored onto the one-set pack for the reason
 * `UpdateAuthoredBook` gives: for a web-authored set the pack *is* the set as
 * far as the shop is concerned, and two names for one thing is how a catalog
 * starts lying.
 *
 * `set_uid` is deliberately not editable. Every sticker a child has already
 * stuck down names it (BL-36's save shape), so renaming it would make those
 * stickers vanish off pages that are already coloured.
 */
class UpdateAuthoredStickerSet
{
    /**
     * @param  array{title?: string, blurb?: string|null, is_free?: bool, sort_order?: int}  $changes
     */
    public function handle(AuthoredStickerSet $set, array $changes): AuthoredStickerSet
    {
        return DB::transaction(function () use ($set, $changes): AuthoredStickerSet {
            $pack = $set->pack;

            if (array_key_exists('title', $changes)) {
                $set->title = $changes['title'];
                $pack->title = $changes['title'];
            }

            if (array_key_exists('blurb', $changes)) {
                $set->blurb = $changes['blurb'];
                $pack->blurb = $changes['blurb'];
            }

            if (array_key_exists('sort_order', $changes)) {
                $set->sort_order = $changes['sort_order'];
            }

            if (array_key_exists('is_free', $changes)) {
                $pack->is_free = $changes['is_free'];
            }

            $set->save();
            $pack->save();

            return $set;
        });
    }
}
