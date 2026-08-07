<?php

namespace App\Actions\Authoring;

use App\Models\AuthoredBook;
use App\Models\Pack;
use Illuminate\Support\Facades\DB;

/**
 * `POST /admin/books` — a new book, and the one-book pack it will publish into
 * (BL-24, DLC_SERVER.md §10.3).
 *
 * The pack is created **with** the book, not lazily at publish time, and its
 * slug *is* the `book_uid`. Two reasons:
 *
 * - Packs remain the delivery and entitlement unit. The game client knows
 *   nothing about a book outside a pack and BL-24 deliberately did not teach it
 *   — the operator thinks in books, the wire format did not move an inch.
 * - The slug is the pack's permanent address in every URL the game builds
 *   (§11), so it has to be reserved at the moment the uid is, or two books
 *   created a second apart could race for it.
 *
 * The pack starts as a **draft**: nothing about creating a book puts anything
 * in the catalog. `is_free` is chosen here because it is a property of how the
 * pack is acquired, and changing it later is a pricing decision, not an
 * authoring one — though `UpdateAuthoredBook` allows it while there is still
 * nothing published.
 */
class CreateAuthoredBook
{
    public function handle(string $bookUid, string $title, ?string $blurb = null, bool $isFree = false): AuthoredBook
    {
        return DB::transaction(function () use ($bookUid, $title, $blurb, $isFree): AuthoredBook {
            $pack = new Pack;
            $pack->fill([
                'slug' => $bookUid,
                'title' => $title,
                'blurb' => $blurb,
                'is_free' => $isFree,
            ]);
            $pack->status = Pack::STATUS_DRAFT;
            $pack->save();

            $book = new AuthoredBook;
            $book->fill(['book_uid' => $bookUid, 'title' => $title, 'blurb' => $blurb]);
            $book->pack()->associate($pack);
            $book->save();

            return $book;
        });
    }
}
