<?php

namespace App\Actions\Authoring;

use App\Models\AuthoredBook;
use App\Models\Book;
use App\Models\Pack;
use App\Models\Page;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;

/**
 * `DELETE /admin/books/{book_uid}` — and the one place BL-24 has a rule that is
 * not obvious (§10.3, §7.3).
 *
 * **A book that was never published is deleted outright.** Its pack has no
 * released version, nobody owns it, nobody has downloaded it, and leaving a
 * dead slug behind would permanently reserve a `book_uid` for a mistake.
 *
 * **A book that has been published is retired instead.** Its pack keeps its
 * rows, its archives and its `files/` tree, and the catalog keeps serving them
 * to the households that own it — `Pack::scopeDownloadable()` includes
 * `retired` precisely so that delisting never takes a book off a child's
 * shelf. Only the authoring workspace goes, because that is draft state and
 * nothing a player can see.
 *
 * The `book_uid` stays claimed in either case for a published book, which is
 * correct: uids are never reused (§6.1).
 */
class DeleteAuthoredBook
{
    public const DELETED = 'deleted';

    public const RETIRED = 'retired';

    /**
     * @return self::DELETED|self::RETIRED what actually happened to the pack
     */
    public function handle(AuthoredBook $book): string
    {
        $pack = $book->pack;
        $everPublished = $pack->versions()->whereNotNull('published_at')->exists();
        $slug = $pack->slug;

        DB::transaction(function () use ($book, $pack, $everPublished): void {
            $book->pages()->delete();
            $book->delete();

            if ($everPublished) {
                $pack->status = Pack::STATUS_RETIRED;
                $pack->save();

                return;
            }

            /** @var array<int, int> $bookIds */
            $bookIds = $pack->books()->pluck('id')->all();

            if ($bookIds !== []) {
                Page::query()->whereIn('book_id', $bookIds)->delete();
                Book::query()->whereIn('id', $bookIds)->delete();
            }

            $pack->entitlements()->delete();
            $pack->versions()->delete();
            $pack->delete();
        });

        if (! $everPublished) {
            // A disk cannot be rolled back, so the bytes go after the rows —
            // the same ordering the account-deletion sweep uses. Content-
            // addressed assets are deliberately left alone: they are shared by
            // digest and another pack may be standing on the same blob.
            Storage::disk((string) config('coloringbook.storage.packs_disk'))->deleteDirectory($slug);
        }

        return $everPublished ? self::RETIRED : self::DELETED;
    }
}
