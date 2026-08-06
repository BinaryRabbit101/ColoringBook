<?php

namespace App\Services;

/**
 * The progress merge rule of DLC_SERVER.md §6.3, and nothing else.
 *
 *     page_statuses[i]    = max(a[i], b[i])  under untouched < in_progress < complete
 *     furthest_page_index = max(a, b)
 *     current_page_index  = from whichever side has the newer client_updated_at
 *
 * Pure: no clock, no database, no request. Both the server and (eventually)
 * the client run the identical rule, which is what makes a sync safe to replay
 * — the merge is **commutative** and **idempotent**, so a retry, a duplicated
 * push or an out-of-order delivery all land on the same state. That is the
 * whole reason a sync conflict never has to become a dialog in a child's face.
 *
 * Two details the design leaves implicit, pinned down here:
 *
 * - **Unequal page counts.** A device on an older version of a book may hold
 *   fewer pages than the server. The shorter side is padded with `untouched`,
 *   which is the merge's identity, and the result is as long as the longer
 *   side. No page is ever dropped.
 * - **Equal timestamps.** "Whichever side is newer" has no answer when the two
 *   are the same instant, and picking "the left one" would break commutativity
 *   outright. The tie-break is `max(current_page_index)` — deterministic,
 *   symmetric, and idempotent.
 *
 * The merged `client_updated_at` is the later of the two, which is what keeps
 * the rule idempotent when the result is merged again with either input.
 */
final class ProgressMerge
{
    public const UNTOUCHED = 'untouched';

    public const IN_PROGRESS = 'in_progress';

    public const COMPLETE = 'complete';

    /**
     * The total order the per-page max is taken under: position = rank.
     *
     * @var list<string>
     */
    private const ORDER = [
        self::UNTOUCHED,
        self::IN_PROGRESS,
        self::COMPLETE,
    ];

    /**
     * Every status the API will accept, for validation.
     *
     * @return list<string>
     */
    public static function statuses(): array
    {
        return self::ORDER;
    }

    /**
     * Merge two views of the same book. Order of the arguments cannot matter.
     */
    public function merge(ProgressState $a, ProgressState $b): ProgressState
    {
        // Carbon implements DateTimeInterface, so the spaceship operator gives
        // a genuine chronological comparison here.
        $newer = $a->clientUpdatedAt <=> $b->clientUpdatedAt;

        return new ProgressState(
            match (true) {
                $newer > 0 => $a->currentPageIndex,
                $newer < 0 => $b->currentPageIndex,
                default => max($a->currentPageIndex, $b->currentPageIndex),
            },
            $this->mergeStatuses($a->pageStatuses, $b->pageStatuses),
            max($a->furthestPageIndex, $b->furthestPageIndex),
            $newer >= 0 ? $a->clientUpdatedAt : $b->clientUpdatedAt,
        );
    }

    /**
     * Per-page max, padding the shorter side with the identity.
     *
     * @param  list<string>  $a
     * @param  list<string>  $b
     * @return list<string>
     */
    private function mergeStatuses(array $a, array $b): array
    {
        $pages = max(count($a), count($b));
        $merged = [];

        for ($page = 0; $page < $pages; $page++) {
            $merged[] = $this->higher(
                $a[$page] ?? self::UNTOUCHED,
                $b[$page] ?? self::UNTOUCHED,
            );
        }

        return $merged;
    }

    /**
     * The greater of two statuses, always as one of the canonical three.
     *
     * Anything unrecognised ranks as `untouched`: a status the server has
     * never heard of must never outrank `complete` and erase a finished page.
     * Normalising the *result* rather than returning whichever argument won
     * is what keeps the rule commutative even when both sides are unknown —
     * returning `$a` on a tie would make merge(a, b) ≠ merge(b, a).
     */
    private function higher(string $a, string $b): string
    {
        $rank = max($this->rank($a), $this->rank($b));

        return self::ORDER[$rank] ?? self::UNTOUCHED;
    }

    private function rank(string $status): int
    {
        $rank = array_search($status, self::ORDER, strict: true);

        return $rank === false ? 0 : $rank;
    }
}
