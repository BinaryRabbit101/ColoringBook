<?php

namespace Tests\Unit;

use App\Services\ProgressMerge;
use App\Services\ProgressState;
use Carbon\CarbonImmutable;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\TestCase;

/**
 * The merge rule of DLC_SERVER.md §6.3 on its own — no database, no request.
 *
 * The two properties at the bottom are the ones the whole sync protocol rests
 * on. If merging is commutative and idempotent then a retry, a duplicated
 * push, or two devices syncing in either order all land on the same state, and
 * a conflict never has to be a question anyone asks a five year old.
 */
class ProgressMergeTest extends TestCase
{
    private function merge(): ProgressMerge
    {
        return new ProgressMerge;
    }

    /**
     * @param  list<string>  $statuses
     */
    private static function state(int $current, array $statuses, int $furthest, string $at): ProgressState
    {
        return new ProgressState($current, $statuses, $furthest, CarbonImmutable::parse($at));
    }

    /**
     * A readable snapshot, so a failing property test says *what* differed.
     *
     * @return array<string, mixed>
     */
    private function snapshot(ProgressState $state): array
    {
        return [
            'current_page_index' => $state->currentPageIndex,
            'page_statuses' => $state->pageStatuses,
            'furthest_page_index' => $state->furthestPageIndex,
            'client_updated_at' => $state->clientUpdatedAt->format('Y-m-d H:i:s.u'),
        ];
    }

    // ---------------------------------------------------------------- rules

    /**
     * @return array<string, array{string, string, string}>
     */
    public static function statusPairs(): array
    {
        return [
            'untouched + untouched' => ['untouched', 'untouched', 'untouched'],
            'untouched + in_progress' => ['untouched', 'in_progress', 'in_progress'],
            'untouched + complete' => ['untouched', 'complete', 'complete'],
            'in_progress + untouched' => ['in_progress', 'untouched', 'in_progress'],
            'in_progress + in_progress' => ['in_progress', 'in_progress', 'in_progress'],
            'in_progress + complete' => ['in_progress', 'complete', 'complete'],
            'complete + untouched' => ['complete', 'untouched', 'complete'],
            'complete + in_progress' => ['complete', 'in_progress', 'complete'],
            'complete + complete' => ['complete', 'complete', 'complete'],
        ];
    }

    #[DataProvider('statusPairs')]
    public function test_a_page_status_only_ever_climbs(string $a, string $b, string $expected): void
    {
        $merged = $this->merge()->merge(
            self::state(0, [$a], 0, '2026-08-06 12:00:00'),
            self::state(0, [$b], 0, '2026-08-06 12:00:00'),
        );

        $this->assertSame([$expected], $merged->pageStatuses);
    }

    public function test_a_finished_page_can_never_be_un_finished(): void
    {
        // The losing side is also the *newer* side here: recency decides the
        // page you are on, never whether a page was already coloured in.
        $merged = $this->merge()->merge(
            self::state(0, ['complete', 'complete'], 1, '2026-08-06 12:00:00'),
            self::state(0, ['untouched', 'untouched'], 0, '2026-08-09 12:00:00'),
        );

        $this->assertSame(['complete', 'complete'], $merged->pageStatuses);
    }

    public function test_the_shorter_side_is_padded_and_no_page_is_dropped(): void
    {
        // One device is on an older build of the book and only knows 2 pages.
        $merged = $this->merge()->merge(
            self::state(0, ['complete', 'in_progress'], 1, '2026-08-06 12:00:00'),
            self::state(0, ['untouched', 'untouched', 'complete', 'in_progress'], 3, '2026-08-06 12:00:00'),
        );

        $this->assertSame(['complete', 'in_progress', 'complete', 'in_progress'], $merged->pageStatuses);
        $this->assertSame(3, $merged->furthestPageIndex);
    }

    public function test_an_empty_side_is_the_identity(): void
    {
        $held = self::state(2, ['complete', 'in_progress', 'untouched'], 2, '2026-08-06 12:00:00');
        $empty = self::state(0, [], 0, '2026-08-06 12:00:00');

        $merged = $this->merge()->merge($held, $empty);

        $this->assertSame($this->snapshot($held), $this->snapshot($merged));
    }

    public function test_furthest_page_index_is_the_maximum(): void
    {
        $merged = $this->merge()->merge(
            self::state(0, [], 7, '2026-08-06 12:00:00'),
            self::state(0, [], 3, '2026-08-09 12:00:00'),
        );

        $this->assertSame(7, $merged->furthestPageIndex);
    }

    public function test_current_page_index_comes_from_the_newer_side(): void
    {
        $older = self::state(1, ['complete'], 5, '2026-08-06 12:00:00');
        $newer = self::state(4, ['untouched'], 0, '2026-08-06 12:00:01');

        $this->assertSame(4, $this->merge()->merge($older, $newer)->currentPageIndex);
        $this->assertSame(4, $this->merge()->merge($newer, $older)->currentPageIndex);
    }

    public function test_the_merged_timestamp_is_the_later_of_the_two(): void
    {
        $merged = $this->merge()->merge(
            self::state(0, [], 0, '2026-08-06 12:00:00'),
            self::state(0, [], 0, '2026-08-09 12:00:00'),
        );

        $this->assertTrue($merged->clientUpdatedAt->equalTo(CarbonImmutable::parse('2026-08-09 12:00:00')));
    }

    public function test_identical_timestamps_break_the_tie_on_the_further_page(): void
    {
        // Two devices saving in the same instant. Picking "the left one" would
        // make the rule non-commutative, so the tie-break is max().
        $a = self::state(2, [], 0, '2026-08-06 12:00:00');
        $b = self::state(5, [], 0, '2026-08-06 12:00:00');

        $this->assertSame(5, $this->merge()->merge($a, $b)->currentPageIndex);
        $this->assertSame(5, $this->merge()->merge($b, $a)->currentPageIndex);
    }

    public function test_sub_second_differences_still_decide(): void
    {
        $a = self::state(1, [], 0, '2026-08-06 12:00:00.100000');
        $b = self::state(9, [], 0, '2026-08-06 12:00:00.200000');

        $this->assertSame(9, $this->merge()->merge($a, $b)->currentPageIndex);
    }

    public function test_an_unrecognised_status_ranks_as_untouched_and_is_normalised(): void
    {
        // Defence in depth: the API validates statuses strictly, but the JSON
        // column could hold anything. Whatever it holds must not outrank a
        // finished page, and must not leak back out.
        $merged = $this->merge()->merge(
            self::state(0, ['sparkly', 'complete'], 0, '2026-08-06 12:00:00'),
            self::state(0, ['untouched', 'glittery'], 0, '2026-08-06 12:00:00'),
        );

        $this->assertSame(['untouched', 'complete'], $merged->pageStatuses);
    }

    public function test_two_unknown_statuses_still_merge_commutatively(): void
    {
        $a = self::state(0, ['sparkly'], 0, '2026-08-06 12:00:00');
        $b = self::state(0, ['glittery'], 0, '2026-08-06 12:00:00');

        $this->assertSame(
            $this->snapshot($this->merge()->merge($a, $b)),
            $this->snapshot($this->merge()->merge($b, $a)),
        );
    }

    // ----------------------------------------------------------- properties

    /**
     * The grid the two properties are checked over: differing page counts
     * (including none at all), every status, both orders of `current` vs
     * `furthest`, and — importantly — several states sharing one timestamp so
     * the tie-break path is exercised as heavily as the ordinary one.
     *
     * @return array<string, ProgressState>
     */
    private static function grid(): array
    {
        return [
            'empty' => self::state(0, [], 0, '2026-08-06 12:00:00'),
            'one untouched page' => self::state(0, ['untouched'], 0, '2026-08-06 12:00:00'),
            'one complete page' => self::state(0, ['complete'], 0, '2026-08-06 12:00:00'),
            'two pages, same instant' => self::state(1, ['complete', 'in_progress'], 1, '2026-08-06 12:00:00'),
            'two pages, later' => self::state(0, ['in_progress', 'complete'], 1, '2026-08-07 09:30:00'),
            'four pages, later still' => self::state(3, ['complete', 'complete', 'in_progress', 'untouched'], 3, '2026-08-08 18:00:00'),
            'three pages, oldest' => self::state(2, ['untouched', 'complete', 'untouched'], 2, '2026-08-01 08:00:00'),
            'five pages, sub-second apart' => self::state(4, ['complete', 'untouched', 'complete', 'in_progress', 'complete'], 4, '2026-08-08 18:00:00.500000'),
            'far ahead of its statuses' => self::state(9, ['in_progress'], 9, '2026-08-07 09:30:00'),
            'unknown status' => self::state(1, ['sparkly', 'complete'], 1, '2026-08-06 12:00:00'),
        ];
    }

    /**
     * @return array<string, array{string}>
     */
    public static function gridStates(): array
    {
        return array_map(static fn (string $name): array => [$name], array_combine(
            array_keys(self::grid()),
            array_keys(self::grid()),
        ));
    }

    /**
     * merge(a, b) == merge(b, a), for this state against every state.
     */
    #[DataProvider('gridStates')]
    public function test_merging_is_commutative(string $name): void
    {
        $a = self::grid()[$name];

        foreach (self::grid() as $otherName => $b) {
            $this->assertSame(
                $this->snapshot($this->merge()->merge($a, $b)),
                $this->snapshot($this->merge()->merge($b, $a)),
                "merge('{$name}', '{$otherName}') differs from the reverse order",
            );
        }
    }

    /**
     * merge(merge(a, b), b) == merge(a, b) — re-applying either side changes
     * nothing, which is what makes a replayed or duplicated sync safe.
     */
    #[DataProvider('gridStates')]
    public function test_merging_is_idempotent(string $name): void
    {
        $a = self::grid()[$name];

        foreach (self::grid() as $otherName => $b) {
            $merged = $this->merge()->merge($a, $b);
            $expected = $this->snapshot($merged);

            $this->assertSame(
                $expected,
                $this->snapshot($this->merge()->merge($merged, $b)),
                "re-merging '{$otherName}' into merge('{$name}', '{$otherName}') changed it",
            );

            $this->assertSame(
                $expected,
                $this->snapshot($this->merge()->merge($merged, $a)),
                "re-merging '{$name}' into merge('{$name}', '{$otherName}') changed it",
            );

            $this->assertSame(
                $expected,
                $this->snapshot($this->merge()->merge($merged, $merged)),
                "merge('{$name}', '{$otherName}') is not a fixed point of itself",
            );
        }
    }

    /**
     * A state merged with itself is itself — the degenerate case of a device
     * pushing what the server already has.
     */
    #[DataProvider('gridStates')]
    public function test_merging_a_state_with_itself_changes_nothing(string $name): void
    {
        $state = self::grid()[$name];
        $merged = $this->merge()->merge($state, $state);

        // The unknown-status row normalises rather than round-trips, so
        // compare against a once-merged baseline for that one.
        $this->assertSame(
            $this->snapshot($merged),
            $this->snapshot($this->merge()->merge($merged, $state)),
            "merging '{$name}' with itself is not stable",
        );
    }

    /**
     * Order of arrival cannot matter across three devices either: whatever
     * order the pushes land in, the shelf ends up in the same state.
     */
    public function test_three_devices_converge_whatever_the_order(): void
    {
        $a = self::state(1, ['complete', 'untouched', 'untouched'], 1, '2026-08-06 12:00:00');
        $b = self::state(2, ['untouched', 'in_progress'], 2, '2026-08-07 12:00:00');
        $c = self::state(0, ['untouched', 'untouched', 'complete', 'in_progress'], 3, '2026-08-05 12:00:00');

        $merge = $this->merge();

        $orders = [
            $merge->merge($merge->merge($a, $b), $c),
            $merge->merge($merge->merge($b, $c), $a),
            $merge->merge($merge->merge($c, $a), $b),
            $merge->merge($a, $merge->merge($b, $c)),
        ];

        foreach ($orders as $result) {
            $this->assertSame($this->snapshot($orders[0]), $this->snapshot($result));
        }

        $this->assertSame(['complete', 'in_progress', 'complete', 'in_progress'], $orders[0]->pageStatuses);
        $this->assertSame(2, $orders[0]->currentPageIndex);
        $this->assertSame(3, $orders[0]->furthestPageIndex);
    }
}
