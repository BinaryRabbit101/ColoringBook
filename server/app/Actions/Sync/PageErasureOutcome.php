<?php

namespace App\Actions\Sync;

use App\Models\BookProgress;
use Carbon\CarbonImmutable;

/**
 * What "Start over" on one page did (BL-18).
 *
 * `progress` carries the revision the device should now hold as its
 * `base_revision`; `pictureDeleted` and `clockMoved` are false when the erase
 * was a replay of one already recorded, which is the idempotent case the
 * client relies on to keep re-sending until a drain succeeds.
 */
final class PageErasureOutcome
{
    public function __construct(
        public readonly BookProgress $progress,
        public readonly int $pageIndex,
        public readonly CarbonImmutable $erasedAt,
        public readonly bool $pictureDeleted,
        public readonly bool $clockMoved,
    ) {}
}
