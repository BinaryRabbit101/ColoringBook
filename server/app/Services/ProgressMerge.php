<?php

namespace App\Services;

use Carbon\CarbonImmutable;

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
 *
 * ### Erasure (BL-18)
 *
 * A rule that only climbs cannot express "this is gone". So an erasure is not
 * an absence here, it is a **clock**, and the merge is defined against it:
 *
 * ```
 * shelf:  a state whose client_updated_at <= shelf_erased_at is the empty book
 * page:   page_erased_at[i] = max(a[i], b[i]); a side whose client_updated_at
 *         is <= that reads `untouched` for page i
 * ```
 *
 * Both are `max` over an instant and both censor each side *independently*, so
 * the rule stays commutative and idempotent — which matters more here than
 * anywhere: an erase that were order-dependent would resurrect on one device
 * and not another, which is precisely the bug BL-18 is about.
 *
 * Ties go to the erase (`<=`, not `<`). A wipe is the newest thing anybody
 * said about the shelf, and the alternative — a save from the same microsecond
 * surviving it — is the failure the button is pressed to avoid.
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
     *
     * `$shelfErasedAt` is the shelf's erase clock (BL-18) — null when the
     * shelf has never been wiped, which is every call this rule saw before
     * BL-18 and therefore the default.
     */
    public function merge(
        ProgressState $a,
        ProgressState $b,
        ?CarbonImmutable $shelfErasedAt = null,
    ): ProgressState {
        // The wipe applies to both sides before anything is compared, so
        // neither can carry a value across it.
        $a = $a->censoredBy($shelfErasedAt);
        $b = $b->censoredBy($shelfErasedAt);

        // Carbon implements DateTimeInterface, so the spaceship operator gives
        // a genuine chronological comparison here.
        $newer = $a->clientUpdatedAt <=> $b->clientUpdatedAt;

        $erasures = $this->mergeErasures($a->pageErasedAt, $b->pageErasedAt);

        return new ProgressState(
            match (true) {
                $newer > 0 => $a->currentPageIndex,
                $newer < 0 => $b->currentPageIndex,
                default => max($a->currentPageIndex, $b->currentPageIndex),
            },
            $this->mergeStatuses($a, $b, $erasures),
            max($a->furthestPageIndex, $b->furthestPageIndex),
            $newer >= 0 ? $a->clientUpdatedAt : $b->clientUpdatedAt,
            $erasures,
        );
    }

    /**
     * Per-page max, padding the shorter side with the identity — and reading
     * a page either side erased more recently than it wrote as `untouched`.
     *
     * @param  list<CarbonImmutable|null>  $erasures
     * @return list<string>
     */
    private function mergeStatuses(ProgressState $a, ProgressState $b, array $erasures): array
    {
        $pages = max(count($a->pageStatuses), count($b->pageStatuses));
        $merged = [];

        for ($page = 0; $page < $pages; $page++) {
            $erasedAt = $erasures[$page] ?? null;

            $merged[] = $this->higher(
                $a->statusAt($page, $erasedAt),
                $b->statusAt($page, $erasedAt),
            );
        }

        return $merged;
    }

    /**
     * Per-page later-of-the-two, padding the shorter side with null.
     *
     * An erase clock is monotonic exactly as `furthest_page_index` is: it only
     * ever moves forward, so `max` is both the rule and the reason replaying a
     * sync cannot undo a reset.
     *
     * @param  list<CarbonImmutable|null>  $a
     * @param  list<CarbonImmutable|null>  $b
     * @return list<CarbonImmutable|null>
     */
    private function mergeErasures(array $a, array $b): array
    {
        $pages = max(count($a), count($b));
        $merged = [];

        for ($page = 0; $page < $pages; $page++) {
            $left = $a[$page] ?? null;
            $right = $b[$page] ?? null;

            $merged[] = match (true) {
                $left === null => $right,
                $right === null => $left,
                default => $left->greaterThan($right) ? $left : $right,
            };
        }

        return ProgressState::trim($merged);
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
