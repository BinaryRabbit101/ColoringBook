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
     * @param  list<CarbonImmutable|null>  $pageErasedAt  index = page, "Start over" pressed at (BL-18)
     */
    public function __construct(
        public readonly int $currentPageIndex,
        public readonly array $pageStatuses,
        public readonly int $furthestPageIndex,
        public readonly CarbonImmutable $clientUpdatedAt,
        public readonly array $pageErasedAt = [],
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
            && $this->clientUpdatedAt->equalTo($other->clientUpdatedAt)
            && $this->erasureFingerprint() === $other->erasureFingerprint();
    }

    /**
     * The page-erase clocks as comparable strings — `CarbonImmutable` objects
     * are never identical under `===`, and `==` would compare them loosely.
     *
     * @return list<string>
     */
    public function erasureFingerprint(): array
    {
        return array_map(
            static fn (?CarbonImmutable $at): string => $at?->utc()->format('Y-m-d H:i:s.u') ?? '',
            self::trim($this->pageErasedAt),
        );
    }

    /**
     * When "Start over" was last pressed on one page, or null.
     */
    public function erasedPageAt(int $page): ?CarbonImmutable
    {
        return $this->pageErasedAt[$page] ?? null;
    }

    /**
     * This state as the shelf's erase clock leaves it (BL-18).
     *
     * A state authored **at or before** an erase did not survive it, and
     * "erase wins the tie" is the whole point: a wipe is the newest statement
     * anybody made about this shelf. What comes back is the empty book, still
     * stamped with the erase instant — so it can never lose a later comparison
     * to the state it replaced, and so merging it again is a no-op.
     */
    public function censoredBy(?CarbonImmutable $erasedAt): self
    {
        if ($erasedAt === null || $this->clientUpdatedAt->greaterThan($erasedAt)) {
            return $this;
        }

        return new self(0, [], 0, $erasedAt, []);
    }

    /**
     * One page's status as the page's own erase clock leaves it.
     *
     * Same rule one level down: a status this side authored at or before the
     * page was reset reads as `untouched`, which is the merge's identity, so
     * it cannot climb back over the reset.
     */
    public function statusAt(int $page, ?CarbonImmutable $erasedAt): string
    {
        if ($erasedAt !== null && ! $this->clientUpdatedAt->greaterThan($erasedAt)) {
            return ProgressMerge::UNTOUCHED;
        }

        return $this->pageStatuses[$page] ?? ProgressMerge::UNTOUCHED;
    }

    /**
     * Drop trailing nulls: a book nobody has ever reset is `[]`, and two
     * states that erased the same pages compare equal however long the client
     * padded its list.
     *
     * @param  list<CarbonImmutable|null>  $clocks
     * @return list<CarbonImmutable|null>
     */
    public static function trim(array $clocks): array
    {
        while ($clocks !== [] && end($clocks) === null) {
            array_pop($clocks);
        }

        return $clocks;
    }
}
