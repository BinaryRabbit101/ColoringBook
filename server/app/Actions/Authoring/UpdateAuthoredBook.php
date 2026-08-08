<?php

namespace App\Actions\Authoring;

use App\Models\Asset;
use App\Models\AuthoredBook;
use Illuminate\Support\Facades\DB;

/**
 * `PATCH /admin/books/{book_uid}` — retitle a book (BL-24, §10.3).
 *
 * The title and blurb are mirrored onto the one-book pack, because for a
 * web-authored book the pack *is* the book as far as the shop is concerned and
 * two names for one thing is how a catalog starts lying.
 *
 * `book_uid` is deliberately not editable. It is the key every `book_progress`
 * and paint row on every device hangs off (§6.1); renaming it would orphan a
 * household's colouring, and "authored once, stable forever" is the whole point
 * of having it.
 *
 * Nothing here reaches published bytes: a title change shows up when the next
 * version is published, exactly like a page change.
 *
 * BL-38 adds the **cover**, and it is a `sometimes` key like the others: an
 * absent `cover` leaves the book's cover alone, a `cover` holding null clears
 * it, and clearing it is not a hole — the publisher falls back to page one's
 * display art, which is the cover every book had before this existed.
 */
class UpdateAuthoredBook
{
    /**
     * @param  array{title?: string, blurb?: string|null, is_free?: bool, cover?: Asset|null}  $changes
     */
    public function handle(AuthoredBook $book, array $changes): AuthoredBook
    {
        return DB::transaction(function () use ($book, $changes): AuthoredBook {
            $pack = $book->pack;

            if (array_key_exists('title', $changes)) {
                $book->title = $changes['title'];
                $pack->title = $changes['title'];
            }

            if (array_key_exists('blurb', $changes)) {
                $book->blurb = $changes['blurb'];
                $pack->blurb = $changes['blurb'];
            }

            if (array_key_exists('is_free', $changes)) {
                $pack->is_free = $changes['is_free'];
            }

            if (array_key_exists('cover', $changes)) {
                $book->cover_asset_id = $changes['cover']?->id;
            }

            $book->save();
            $pack->save();

            return $book;
        });
    }
}
