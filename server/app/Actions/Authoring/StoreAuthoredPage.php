<?php

namespace App\Actions\Authoring;

use App\Jobs\MapAuthoredPage;
use App\Models\Asset;
use App\Models\AuthoredBook;
use App\Models\AuthoredPage;
use Illuminate\Support\Facades\DB;

/**
 * `POST /admin/books/{book_uid}/pages` — add a page (BL-24, §10.3).
 *
 * A page needs exactly one thing to exist: its **detail (display) image**. The
 * masking image is optional and always has been (BL-9, clarified 2026-08-06):
 * when it is there it is the mapping source and its display-resolution resample
 * ships as `page_NN_mask.png` (BL-12); when it is not, the display image maps
 * itself and no mask file appears in the pack.
 *
 * The page is appended at the end. There is no "insert at index" here on
 * purpose — reordering is `UpdateAuthoredPage`'s job, and one mechanism that
 * renumbers a book is easier to trust than two.
 *
 * Creating a page **queues its mapping immediately**. The alternative — a
 * "map this page" button — sounds like control and is really just a second
 * chance to forget, and the whole book is unpublishable until every page has
 * been through the pipeline anyway.
 */
class StoreAuthoredPage
{
    /**
     * @param  array<string, float|int>|null  $tuning  Per-page overrides of
     *                                                 `coloringbook.authoring.tuning`.
     */
    public function handle(
        AuthoredBook $book,
        Asset $display,
        ?Asset $mask = null,
        ?string $title = null,
        ?array $tuning = null,
    ): AuthoredPage {
        $page = DB::transaction(function () use ($book, $display, $mask, $title, $tuning): AuthoredPage {
            $next = (int) ($book->pages()->max('page_index') ?? -1) + 1;

            /** @var AuthoredPage $page */
            $page = $book->pages()->create([
                'page_index' => $next,
                'title' => $title,
                'display_asset_id' => $display->id,
                'mask_asset_id' => $mask?->id,
                'tuning' => $tuning,
            ]);

            $page->forceFill(['mapping_status' => AuthoredPage::STATUS_QUEUED])->save();

            return $page;
        });

        MapAuthoredPage::dispatch($page->id);

        return $page;
    }
}
