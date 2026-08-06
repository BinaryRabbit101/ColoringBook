<?php

namespace App\Services;

use Carbon\CarbonImmutable;

/**
 * One book's progress as a plain immutable value — no database, no request.
 *
 * `ProgressMerge` is defined over this type so the merge rule of
 * DLC_SERVER.md §6.3 can be reasoned about (and property-tested) on its own,
 * away from Eloquent.
 */
final class ProgressState
{
    /**
     * @param  list<string>  $pageStatuses  index = page, value = untouched|in_progress|complete
     */
    public function __construct(
        public readonly int $currentPageIndex,
        public readonly array $pageStatuses,
        public readonly int $furthestPageIndex,
        public readonly CarbonImmutable $clientUpdatedAt,
    ) {}

    /**
     * Value equality — used to tell "the merge changed something" from "this
     * device is re-sending what the server already has".
     */
    public function equals(self $other): bool
    {
        return $this->currentPageIndex === $other->currentPageIndex
            && $this->furthestPageIndex === $other->furthestPageIndex
            && $this->pageStatuses === $other->pageStatuses
            && $this->clientUpdatedAt->equalTo($other->clientUpdatedAt);
    }
}
