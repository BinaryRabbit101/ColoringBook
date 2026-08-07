<?php

namespace App\Actions\Authoring;

use App\Models\AuthoredStickerSet;
use App\Models\Pack;
use Illuminate\Support\Facades\DB;

/**
 * `POST /admin/sticker-sets` — a new sticker set and the one-set pack it will
 * publish into (BL-37).
 *
 * Structurally identical to `CreateAuthoredBook`, and deliberately so: packs
 * remain the delivery and entitlement unit, the slug *is* the uid, and the pack
 * is created **with** the set rather than lazily at publish, because the slug is
 * the pack's permanent address in every URL the game builds (§11).
 *
 * The one thing that differs is `packs.kind`, which is what tells the shop and
 * the client that this pack's payload is `sticker_sets[]` rather than `books[]`.
 * Everything downstream of that — entitlements, signed downloads, delta updates
 * — is byte-for-byte the book path.
 */
class CreateAuthoredStickerSet
{
    public function handle(
        string $setUid,
        string $title,
        ?string $blurb = null,
        bool $isFree = false,
        int $sortOrder = 100,
    ): AuthoredStickerSet {
        return DB::transaction(function () use ($setUid, $title, $blurb, $isFree, $sortOrder): AuthoredStickerSet {
            $pack = new Pack;
            $pack->fill([
                'slug' => $setUid,
                'kind' => Pack::KIND_STICKER_SET,
                'title' => $title,
                'blurb' => $blurb,
                'is_free' => $isFree,
            ]);
            $pack->status = Pack::STATUS_DRAFT;
            $pack->save();

            $set = new AuthoredStickerSet;
            $set->fill([
                'set_uid' => $setUid,
                'title' => $title,
                'blurb' => $blurb,
                'sort_order' => $sortOrder,
            ]);
            $set->pack()->associate($pack);
            $set->save();

            return $set;
        });
    }
}
