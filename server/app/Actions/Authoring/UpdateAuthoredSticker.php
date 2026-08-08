<?php

namespace App\Actions\Authoring;

use App\Models\Asset;
use App\Models\AuthoredSticker;
use Illuminate\Support\Facades\DB;

/**
 * `PATCH /admin/sticker-sets/{set_uid}/stickers/{index}` — retitle, reorder or
 * replace a sticker's art (BL-37).
 *
 * **Replacing the art re-validates it**, in the same call. That is the sticker
 * analogue of BL-24's "anything that changes the mapping re-queues the mapping":
 * leaving yesterday's verdict beside today's image is exactly how a broken file
 * gets published, and it would be this application that created it. There is no
 * job to wait for, because there is no pipeline — `StickerValidation` reads the
 * bytes and the row is correct again before the response goes out.
 *
 * **Reordering renumbers the whole set**, through the same two-phase shuffle
 * `UpdateAuthoredPage` uses and for the same reason: `(set, sticker_index)` is
 * unique, SQLite checks unique indexes per statement, and a straight swap
 * collides on the way past itself.
 *
 * `sticker_id` is editable only while the set has never been published — see
 * the controller. A published id is named by every placement a child has
 * already made.
 */
class UpdateAuthoredSticker
{
    /** Larger than any sticker set anyone will author; the shuffle is one transaction. */
    private const SHUFFLE_OFFSET = 100_000;

    public function __construct(private readonly StoreAuthoredSticker $store) {}

    /**
     * @param  array{
     *     title?: string|null,
     *     sticker_id?: string,
     *     sticker_index?: int,
     *     image?: Asset,
     *     anim?: array{hframes: int, vframes: int, frames: int, fps: float}|null,
     * }  $changes  An `anim` key holding null turns an animated sticker back
     *              into a still one; omitting the key leaves it alone.
     */
    public function handle(AuthoredSticker $sticker, array $changes): AuthoredSticker
    {
        DB::transaction(function () use ($sticker, $changes): void {
            if (array_key_exists('title', $changes)) {
                $sticker->title = $changes['title'];
            }

            if (array_key_exists('sticker_id', $changes)) {
                $sticker->sticker_id = $changes['sticker_id'];
            }

            // BL-38. Changing the grid changes what the same bytes MEAN, so it
            // re-validates for the same reason replacing the art does: the
            // stored verdict has to describe the sheet as it will actually be
            // sliced.
            $animChanged = array_key_exists('anim', $changes) && $changes['anim'] !== $sticker->anim;

            if ($animChanged) {
                $sticker->anim = $changes['anim'];
            }

            $sticker->save();

            if (array_key_exists('image', $changes)) {
                $this->store->revalidate($sticker, $changes['image']);
            } elseif ($animChanged) {
                $this->store->revalidate($sticker, $sticker->imageAsset);
            }

            if (array_key_exists('sticker_index', $changes)) {
                $this->moveTo($sticker, $changes['sticker_index']);
            }
        });

        return $sticker->refresh();
    }

    /**
     * Put `$sticker` at `$target` and close the gap it left, renumbering the set
     * to a dense 0..n-1 run.
     */
    private function moveTo(AuthoredSticker $sticker, int $target): void
    {
        $set = $sticker->set;

        /** @var list<AuthoredSticker> $stickers */
        $stickers = $set->stickers()->get()->all();

        $target = max(0, min($target, count($stickers) - 1));
        $current = null;

        foreach ($stickers as $position => $candidate) {
            if ($candidate->id === $sticker->id) {
                $current = $position;
            }
        }

        if ($current === null || $current === $target) {
            return;
        }

        $moved = array_splice($stickers, $current, 1);
        array_splice($stickers, $target, 0, $moved);

        // Phase one: out of the way, so nothing collides on the way past.
        foreach ($stickers as $position => $candidate) {
            $candidate->forceFill(['sticker_index' => self::SHUFFLE_OFFSET + $position])->save();
        }

        // Phase two: back down into 0..n-1, in the new order.
        foreach ($stickers as $position => $candidate) {
            $candidate->forceFill(['sticker_index' => $position])->save();
        }
    }
}
