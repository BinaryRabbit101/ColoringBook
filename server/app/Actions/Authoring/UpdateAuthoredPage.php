<?php

namespace App\Actions\Authoring;

use App\Jobs\MapAuthoredPage;
use App\Models\Asset;
use App\Models\AuthoredPage;
use Illuminate\Support\Facades\DB;

/**
 * `PATCH /admin/books/{book_uid}/pages/{index}` — retitle, reorder, or replace
 * a page's art (BL-24, §10.3).
 *
 * ## Anything that changes the mapping re-queues the mapping
 *
 * A new detail image, a new mask, a mask removed, a tuning knob moved: all four
 * invalidate the ID map, the regions JSON and the §10.1 verdict. So the derived
 * columns are **cleared**, not left stale, and a fresh job is queued. Leaving
 * yesterday's ID map beside today's art is the exact failure `PackValidation`'s
 * bijection check exists to catch, and it would be this application that
 * created it.
 *
 * A retitle or a reorder changes neither pixel, so neither re-maps.
 *
 * ## Reordering renumbers the whole book
 *
 * `(authored_book_id, page_index)` is unique, so a move is a two-phase shuffle:
 * every page is pushed out of the way into a range nothing occupies, then
 * written back in its new order. A straight swap would collide on the way past
 * itself, and SQLite checks unique indexes per statement — there is no deferred
 * constraint to hide behind.
 */
class UpdateAuthoredPage
{
    /**
     * Every page index is temporarily offset by this while a book is being
     * renumbered. Larger than any book anyone will ever author, and the whole
     * shuffle is inside one transaction.
     */
    private const SHUFFLE_OFFSET = 100_000;

    /**
     * @param  array{
     *     title?: string|null,
     *     page_index?: int,
     *     display?: Asset,
     *     mask?: Asset|null,
     *     tuning?: array<string, float|int>|null,
     * }  $changes  A `mask` key holding null **removes** the mask; omitting the
     *              key leaves it alone.
     */
    public function handle(AuthoredPage $page, array $changes): AuthoredPage
    {
        $remap = false;

        DB::transaction(function () use ($page, $changes, &$remap): void {
            if (array_key_exists('title', $changes)) {
                $page->title = $changes['title'];
            }

            if (array_key_exists('display', $changes)) {
                $page->display_asset_id = $changes['display']->id;
                $remap = true;
            }

            if (array_key_exists('mask', $changes)) {
                $incoming = $changes['mask']?->id;

                if ($incoming !== $page->mask_asset_id) {
                    $page->mask_asset_id = $incoming;
                    $remap = true;
                }
            }

            if (array_key_exists('tuning', $changes) && $changes['tuning'] !== $page->tuning) {
                $page->tuning = $changes['tuning'];
                $remap = true;
            }

            if ($remap) {
                $page->forceFill([
                    'idmap_asset_id' => null,
                    'regions_asset_id' => null,
                    'mask_artifact_asset_id' => null,
                    'image_w' => null,
                    'image_h' => null,
                    'region_count' => null,
                    'mapping_status' => AuthoredPage::STATUS_QUEUED,
                    'mapping_error' => null,
                    'mapping_log' => null,
                    'mapped_at' => null,
                    'validation_errors' => null,
                    'validation_warnings' => null,
                ]);
            }

            $page->save();

            if (array_key_exists('page_index', $changes)) {
                $this->moveTo($page, $changes['page_index']);
            }
        });

        if ($remap) {
            MapAuthoredPage::dispatch($page->id);
        }

        return $page->refresh();
    }

    /**
     * Put `$page` at `$target` and close the gap it left, renumbering the book
     * to a dense 0..n-1 run.
     */
    private function moveTo(AuthoredPage $page, int $target): void
    {
        $book = $page->book;

        /** @var list<AuthoredPage> $pages */
        $pages = $book->pages()->get()->all();

        $target = max(0, min($target, count($pages) - 1));
        $current = null;

        foreach ($pages as $position => $candidate) {
            if ($candidate->id === $page->id) {
                $current = $position;
            }
        }

        if ($current === null || $current === $target) {
            return;
        }

        $moved = array_splice($pages, $current, 1);
        array_splice($pages, $target, 0, $moved);

        // Phase one: out of the way, so nothing collides on the way past.
        foreach ($pages as $position => $candidate) {
            $candidate->forceFill(['page_index' => self::SHUFFLE_OFFSET + $position])->save();
        }

        // Phase two: back down into 0..n-1, in the new order.
        foreach ($pages as $position => $candidate) {
            $candidate->forceFill(['page_index' => $position])->save();
        }
    }
}
