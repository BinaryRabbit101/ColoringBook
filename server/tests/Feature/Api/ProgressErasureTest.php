<?php

namespace Tests\Feature\Api;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\ShelfErasure;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\PaintsPages;
use Tests\TestCase;

/**
 * `DELETE /api/v1/sync/progress` — "Erase all progress" across devices
 * (BL-18, DLC_SERVER.md §6.3 "Erasure").
 *
 * The bug this closes: the §6.3 merge only ever climbs, so a local erase used
 * to be an *absence*, and an absence always loses. Every test below is really
 * one question — after the erase, can anything put the colouring back?
 */
class ProgressErasureTest extends TestCase
{
    use PaintsPages, RefreshDatabase;

    /**
     * One book as a device would push it.
     *
     * @param  list<string>  $statuses
     * @return array<string, mixed>
     */
    private function push(
        string $bookUid = 'coyote-2026',
        int $baseRevision = 0,
        int $current = 0,
        array $statuses = ['complete', 'complete'],
        int $furthest = 1,
        ?string $at = null,
    ): array {
        return [
            'book_uid' => $bookUid,
            'base_revision' => $baseRevision,
            'current_page_index' => $current,
            'page_statuses' => $statuses,
            'furthest_page_index' => $furthest,
            'client_updated_at' => $at ?? CarbonImmutable::now()->toIso8601String(),
        ];
    }

    // ------------------------------------------------------------- the wipe

    public function test_it_deletes_the_shelf_and_records_when(): void
    {
        $disk = $this->fakePaintStorage();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('first'))->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('second'))->assertCreated();
        $this->assertNotEmpty($disk->allFiles());

        $at = CarbonImmutable::parse('2026-08-07 10:00:00.500000');

        $response = $this->withToken($bearer)->deleteJson('/api/v1/sync/progress', [
            'erased_at' => $at->utc()->format('Y-m-d\TH:i:s.up'),
        ]);

        $response->assertOk()
            ->assertJsonPath('books_erased', 1)
            ->assertJsonPath('pictures_erased', 1)
            ->assertJsonStructure(['erased_at', 'books_erased', 'pictures_erased', 'server_time']);

        $this->assertSame(0, BookProgress::query()->count());
        $this->assertDatabaseCount('paint_layers', 0);
        $this->assertDatabaseCount('retained_paint_layers', 0);
        $this->assertSame([], $disk->allFiles());

        // The one thing that survives: the instant. Microseconds included —
        // the censor is a `<=` against a client clock that has them.
        $this->assertSame(
            $at->format('Y-m-d H:i:s.u'),
            ShelfErasure::query()->sole()->erased_at->format('Y-m-d H:i:s.u'),
        );
    }

    public function test_the_pull_publishes_the_clock_even_with_no_books_left(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);
        BookProgress::factory()->for($user)->create(['book_uid' => 'coyote-2026']);

        $this->withToken($bearer)->deleteJson('/api/v1/sync/progress')->assertOk();

        $this->withToken($bearer)->getJson('/api/v1/sync/progress')
            ->assertOk()
            ->assertJsonCount(0, 'books')
            ->assertJsonPath('erased_at', fn (?string $at): bool => is_string($at));
    }

    /**
     * A cursored pull is the shape a device that has synced before uses, and
     * it is exactly the one that would learn nothing from an absence: the
     * rows are gone, so nothing comes back. The clock is deliberately not
     * filtered by `since`.
     */
    public function test_a_cursored_pull_still_learns_of_the_wipe(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);
        BookProgress::factory()->for($user)->create(['book_uid' => 'coyote-2026']);

        $cursor = $this->withToken($bearer)->getJson('/api/v1/sync/progress')->json('server_time');

        $this->withToken($bearer)->deleteJson('/api/v1/sync/progress')->assertOk();

        $this->withToken($bearer)
            ->getJson('/api/v1/sync/progress?since='.urlencode((string) $cursor))
            ->assertOk()
            ->assertJsonCount(0, 'books')
            ->assertJsonPath('erased_at', fn (?string $at): bool => is_string($at));
    }

    public function test_a_shelf_that_was_never_erased_reports_null(): void
    {
        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/sync/progress')
            ->assertOk()
            ->assertJsonPath('erased_at', null);
    }

    // --------------------------------------------- the device that was away

    /**
     * The whole point. A tablet that was off during the wipe wakes up holding
     * a full shelf and a stale `base_revision`, and pushes it. Before BL-18
     * that push *recreated* every book ("recreating progress beats losing
     * it") and the erase was undone.
     */
    public function test_a_stale_push_after_a_wipe_cannot_resurrect_the_shelf(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $painted = CarbonImmutable::parse('2026-08-07 09:00:00');
        BookProgress::factory()->for($user)->create([
            'book_uid' => 'coyote-2026',
            'revision' => 4,
            'page_statuses' => ['complete', 'complete'],
            'furthest_page_index' => 1,
            'client_updated_at' => $painted,
        ]);

        $this->withToken($bearer)->deleteJson('/api/v1/sync/progress', [
            'erased_at' => CarbonImmutable::parse('2026-08-07 10:00:00')->toIso8601String(),
        ])->assertOk();

        $this->withToken($bearer)->putJson('/api/v1/sync/progress', [
            'books' => [$this->push(baseRevision: 4, at: $painted->toIso8601String())],
        ])->assertOk()->assertJsonPath('results.0.conflict', false);

        $row = BookProgress::query()->sole();
        $this->assertSame([], $row->pageStatuses());
        $this->assertSame(0, $row->furthest_page_index);
        $this->assertSame(0, $row->current_page_index);
    }

    public function test_colouring_done_after_the_wipe_still_syncs(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->withToken($bearer)->deleteJson('/api/v1/sync/progress', [
            'erased_at' => CarbonImmutable::parse('2026-08-07 10:00:00')->toIso8601String(),
        ])->assertOk();

        $this->withToken($bearer)->putJson('/api/v1/sync/progress', [
            'books' => [$this->push(
                statuses: ['in_progress', 'untouched'],
                furthest: 0,
                at: CarbonImmutable::parse('2026-08-07 11:00:00')->toIso8601String(),
            )],
        ])->assertOk();

        $this->assertSame(['in_progress', 'untouched'], BookProgress::query()->sole()->pageStatuses());
    }

    /**
     * A picture painted before the wipe cannot walk back in through the paint
     * endpoints either — the shelf row is gone, so it would be recreated, and
     * with it a book the parent just erased.
     */
    public function test_a_stale_picture_upload_after_a_wipe_is_refused(): void
    {
        $this->fakePaintStorage();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);
        $painted = CarbonImmutable::parse('2026-08-07 09:00:00');

        $this->upload($bearer, 'coyote-2026', 0, $this->png('before'), $painted)->assertCreated();

        $this->withToken($bearer)->deleteJson('/api/v1/sync/progress', [
            'erased_at' => CarbonImmutable::parse('2026-08-07 10:00:00')->toIso8601String(),
        ])->assertOk();

        $this->negotiate($bearer, 'coyote-2026', 0, $this->png('before'), $painted)
            ->assertStatus(409)
            ->assertJsonPath('error.code', 'PROGRESS_ERASED');

        $this->assertDatabaseCount('paint_layers', 0);
    }

    // ----------------------------------------------------------- monotonic

    public function test_replaying_an_older_erase_never_moves_the_clock_back(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $later = CarbonImmutable::parse('2026-08-07 12:00:00');
        $earlier = CarbonImmutable::parse('2026-08-07 08:00:00');

        $this->withToken($bearer)->deleteJson('/api/v1/sync/progress', [
            'erased_at' => $later->toIso8601String(),
        ])->assertOk();

        $this->withToken($bearer)->deleteJson('/api/v1/sync/progress', [
            'erased_at' => $earlier->toIso8601String(),
        ])->assertOk()->assertJsonPath(
            'erased_at',
            $later->utc()->format('Y-m-d\TH:i:s.up'),
        );

        $this->assertSame(1, ShelfErasure::query()->count());
    }

    public function test_an_erase_stamped_in_the_far_future_is_clamped(): void
    {
        $user = User::factory()->create();

        $response = $this->withToken($this->issueDeviceToken($user))
            ->deleteJson('/api/v1/sync/progress', [
                'erased_at' => CarbonImmutable::now()->addYears(5)->toIso8601String(),
            ]);

        $response->assertOk();

        $this->assertTrue(
            ShelfErasure::query()->sole()->erased_at->lessThan(CarbonImmutable::now()->addDay()),
            'a five-year-ahead erase would keep the shelf empty for five years',
        );
    }

    // -------------------------------------------------------------- scoping

    public function test_it_erases_one_shelf_and_leaves_the_others_alone(): void
    {
        $disk = $this->fakePaintStorage();

        $user = User::factory()->create();
        $child = ChildProfile::factory()->for($user)->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('account'))->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('child'), null, $child->ulid)->assertCreated();

        $this->withToken($bearer)->deleteJson('/api/v1/sync/progress')->assertOk();

        $this->assertSame(1, BookProgress::query()->count());
        $this->assertSame($child->id, BookProgress::query()->sole()->child_profile_id);
        $this->assertCount(1, $disk->allFiles());
    }

    public function test_another_households_shelf_is_untouched(): void
    {
        $user = User::factory()->create();
        $stranger = User::factory()->create();
        BookProgress::factory()->for($stranger)->create(['book_uid' => 'coyote-2026']);

        $this->withToken($this->issueDeviceToken($user))
            ->deleteJson('/api/v1/sync/progress')
            ->assertOk()
            ->assertJsonPath('books_erased', 0);

        $this->assertSame(1, BookProgress::query()->count());
    }

    public function test_a_profile_that_is_not_ours_is_a_404(): void
    {
        $user = User::factory()->create();
        $stranger = ChildProfile::factory()->for(User::factory())->create();

        $this->withToken($this->issueDeviceToken($user))
            ->deleteJson('/api/v1/sync/progress', ['profile' => $stranger->ulid])
            ->assertNotFound();

        $this->assertSame(0, ShelfErasure::query()->count());
    }

    public function test_it_needs_the_save_sync_ability(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user, abilities: ['packs:read']);

        $this->withToken($bearer)->deleteJson('/api/v1/sync/progress')->assertForbidden();
    }

    public function test_a_guest_cannot_erase_anything(): void
    {
        $this->deleteJson('/api/v1/sync/progress')->assertUnauthorized();
    }
}
