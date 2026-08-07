<?php

namespace App\Actions\Authoring;

use App\Models\AuthoredPage;
use Illuminate\Support\Facades\DB;

/**
 * `DELETE /admin/books/{book_uid}/pages/{index}` — remove a page and close the
 * gap (BL-24, §10.3).
 *
 * Renumbering is not optional. `page_index` is what the manifest ships, what
 * the game's page cursor counts in, and what every `page_statuses` array on
 * every device is positional against — a book with a hole at index 2 would
 * publish a manifest the client reads as a four-page book with a missing page.
 *
 * The page's **assets are left alone**, deliberately. They are content-
 * addressed and shared by digest: the same drawing may be page 3 of another
 * book, and a published release is still standing on those bytes. Nothing in
 * this application deletes an `assets` blob (§7.3's rule, generalised).
 */
class DeleteAuthoredPage
{
    public function handle(AuthoredPage $page): void
    {
        DB::transaction(function () use ($page): void {
            $book = $page->book;
            $page->delete();

            /** @var list<AuthoredPage> $remaining */
            $remaining = $book->pages()->get()->all();

            foreach ($remaining as $position => $candidate) {
                if ($candidate->page_index !== $position) {
                    $candidate->forceFill(['page_index' => $position])->save();
                }
            }
        });
    }
}
