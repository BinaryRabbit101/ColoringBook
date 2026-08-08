<?php

namespace Tests\Feature\Api;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\PaintLayer;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Testing\TestResponse;
use Tests\Concerns\PaintsPages;
use Tests\TestCase;

/**
 * `DELETE /api/v1/sync/paint/{book_uid}/{page}` — the page's "Start over"
 * (BL-7) pushed as a state (BL-18, DLC_SERVER.md §6.3 "Erasure").
 *
 * Two halves, one instant. The picture has to lose last-write-wins to the
 * reset, and the page's *status* has to stop climbing back to `complete`;
 * before BL-18 the local reset lost both comparisons on the next pull and the
 * page came back finished and painted.
 */
class PageErasureTest extends TestCase
{
    use PaintsPages, RefreshDatabase;

    private function erase(
        string $bearer,
        string $bookUid,
        int $page,
        ?CarbonImmutable $at = null,
        ?string $profile = null,
    ): TestResponse {
        $body = [];

        if ($at !== null) {
            $body['client_erased_at'] = $at->utc()->format('Y-m-d\TH:i:s.up');
        }

        if ($profile !== null) {
            $body['profile'] = $profile;
        }

        return $this->withToken($bearer)
            ->deleteJson("/api/v1/sync/paint/{$bookUid}/{$page}", $body);
    }

    /**
     * One book as a device would push it.
     *
     * @param  list<string>  $statuses
     * @return array<string, mixed>
     */
    private function push(int $baseRevision, array $statuses, string $at): array
    {
        return [
            'book_uid' => 'coyote-2026',
            'base_revision' => $baseRevision,
            'current_page_index' => 0,
            'page_statuses' => $statuses,
            'furthest_page_index' => 1,
            'client_updated_at' => $at,
        ];
    }

    // ------------------------------------------------------------ the reset

    public function test_it_deletes_the_picture_and_stamps_the_page(): void
    {
        $disk = $this->fakePaintStorage();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $painted = CarbonImmutable::parse('2026-08-07 09:00:00');
        $this->upload($bearer, 'coyote-2026', 0, $this->png('a'), $painted)->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('b'), $painted->addMinute())->assertCreated();

        $this->assertDatabaseCount('retained_paint_layers', 1);

        $erasedAt = CarbonImmutable::parse('2026-08-07 10:00:00.750000');
        $before = BookProgress::query()->sole()->revision;

        $this->erase($bearer, 'coyote-2026', 0, $erasedAt)
            ->assertOk()
            ->assertJsonPath('page_index', 0)
            ->assertJsonPath('picture_erased', true)
            ->assertJsonPath('erased_at', $erasedAt->utc()->format('Y-m-d\TH:i:s.up'));

        $this->assertDatabaseCount('paint_layers', 0);
        // A deliberate reset takes the 30-day net with it: that net is for a
        // race nobody chose to lose, and this is the opposite.
        $this->assertDatabaseCount('retained_paint_layers', 0);
        $this->assertSame([], $disk->allFiles());

        $row = BookProgress::query()->sole();
        $this->assertSame($before + 1, $row->revision, 'the reset must move the revision');
        $this->assertSame(
            $erasedAt->format('Y-m-d H:i:s.u'),
            $row->erasedPageAt(0)?->format('Y-m-d H:i:s.u'),
        );
    }

    public function test_the_clock_reaches_the_other_devices_through_the_pull(): void
    {
        $this->fakePaintStorage();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 1, $this->png('a'))->assertCreated();
        $this->erase($bearer, 'coyote-2026', 1)->assertOk();

        $this->withToken($bearer)->getJson('/api/v1/sync/progress')
            ->assertOk()
            ->assertJsonPath('books.0.page_erased_at.0', null)
            ->assertJsonPath('books.0.page_erased_at.1', fn (?string $at): bool => is_string($at));
    }

    public function test_a_book_nobody_has_reset_reports_an_empty_list(): void
    {
        $user = User::factory()->create();
        BookProgress::factory()->for($user)->create(['book_uid' => 'coyote-2026']);

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/sync/progress')
            ->assertOk()
            ->assertJsonPath('books.0.page_erased_at', []);
    }

    // ------------------------------------------------- the status that lied

    /**
     * The BL-18 bug in miniature: device B still holds `complete` for a page
     * device A reset. Before this, the merge climbed it straight back and the
     * shelf showed a finished badge over a blank page.
     */
    public function test_a_stale_device_cannot_put_the_complete_badge_back(): void
    {
        $this->fakePaintStorage();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $painted = CarbonImmutable::parse('2026-08-07 09:00:00');

        $this->withToken($bearer)->putJson('/api/v1/sync/progress', [
            'books' => [$this->push(0, ['complete', 'complete'], $painted->toIso8601String())],
        ])->assertOk();

        $this->upload($bearer, 'coyote-2026', 1, $this->png('a'), $painted)->assertCreated();

        $this->erase($bearer, 'coyote-2026', 1, CarbonImmutable::parse('2026-08-07 10:00:00'))->assertOk();

        $revision = BookProgress::query()->sole()->revision;

        // Device B, pushing what it has held since before the reset.
        $this->withToken($bearer)->putJson('/api/v1/sync/progress', [
            'books' => [$this->push($revision, ['complete', 'complete'], $painted->toIso8601String())],
        ])->assertOk()->assertJsonPath('results.0.conflict', false);

        $this->assertSame(['complete', 'untouched'], BookProgress::query()->sole()->pageStatuses());
    }

    public function test_a_page_coloured_again_after_the_reset_climbs_normally(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->erase($bearer, 'coyote-2026', 1, CarbonImmutable::parse('2026-08-07 10:00:00'))->assertOk();

        $revision = BookProgress::query()->sole()->revision;

        $this->withToken($bearer)->putJson('/api/v1/sync/progress', [
            'books' => [$this->push(
                $revision,
                ['untouched', 'complete'],
                CarbonImmutable::parse('2026-08-07 11:00:00')->toIso8601String(),
            )],
        ])->assertOk();

        $this->assertSame(['untouched', 'complete'], BookProgress::query()->sole()->pageStatuses());
    }

    // ---------------------------------------------------------- the picture

    public function test_a_picture_painted_before_the_reset_is_refused(): void
    {
        $this->fakePaintStorage();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $painted = CarbonImmutable::parse('2026-08-07 09:00:00');
        $this->erase($bearer, 'coyote-2026', 0, CarbonImmutable::parse('2026-08-07 10:00:00'))->assertOk();

        $this->negotiate($bearer, 'coyote-2026', 0, $this->png('stale'), $painted)
            ->assertStatus(409)
            ->assertJsonPath('error.code', 'PAINT_ERASED')
            ->assertJsonPath(
                'error.details.erased_at',
                CarbonImmutable::parse('2026-08-07 10:00:00')->utc()->format('Y-m-d\TH:i:s.up'),
            );

        $this->assertDatabaseCount('paint_layers', 0);
    }

    /**
     * The negotiation is a courtesy; the `PUT` is the gate. A client that
     * skipped straight to the bytes must be refused too.
     */
    public function test_the_upload_itself_refuses_a_picture_from_before_the_reset(): void
    {
        $this->fakePaintStorage();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $painted = CarbonImmutable::parse('2026-08-07 09:00:00');
        $contents = $this->png('stale');

        $this->erase($bearer, 'coyote-2026', 0, CarbonImmutable::parse('2026-08-07 10:00:00'))->assertOk();

        $this->putRaw(
            $bearer,
            $this->uploadUrl('coyote-2026', 0, $contents, $painted),
            $contents,
            ['Content-Type' => 'image/png', 'Content-Digest' => $this->contentDigest($contents)],
        )->assertStatus(409)->assertJsonPath('error.code', 'PAINT_ERASED');

        $this->assertDatabaseCount('paint_layers', 0);
    }

    public function test_a_picture_painted_after_the_reset_is_accepted(): void
    {
        $this->fakePaintStorage();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->erase($bearer, 'coyote-2026', 0, CarbonImmutable::parse('2026-08-07 10:00:00'))->assertOk();

        $this->upload(
            $bearer,
            'coyote-2026',
            0,
            $this->png('after'),
            CarbonImmutable::parse('2026-08-07 11:00:00'),
        )->assertCreated();

        $this->assertDatabaseCount('paint_layers', 1);
    }

    /**
     * The mirror image: another device painted the page *after* the reset was
     * made offline. §6.3 says the later picture wins, so the reset loses and
     * says so, which is what tells the erasing device to pull instead.
     */
    public function test_a_reset_older_than_the_stored_picture_loses(): void
    {
        $this->fakePaintStorage();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload(
            $bearer,
            'coyote-2026',
            0,
            $this->png('newer'),
            CarbonImmutable::parse('2026-08-07 12:00:00'),
        )->assertCreated();

        $this->erase($bearer, 'coyote-2026', 0, CarbonImmutable::parse('2026-08-07 10:00:00'))
            ->assertStatus(409)
            ->assertJsonPath('error.code', 'PAINT_STALE')
            ->assertJsonPath('error.details.server.page_index', 0);

        $this->assertDatabaseCount('paint_layers', 1);
        $this->assertNull(BookProgress::query()->sole()->erasedPageAt(0));
    }

    public function test_a_reset_wins_an_exact_tie_with_the_picture(): void
    {
        $this->fakePaintStorage();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);
        $at = CarbonImmutable::parse('2026-08-07 12:00:00.125000');

        $this->upload($bearer, 'coyote-2026', 0, $this->png('tie'), $at)->assertCreated();

        $this->erase($bearer, 'coyote-2026', 0, $at)->assertOk();

        $this->assertDatabaseCount('paint_layers', 0);
    }

    // --------------------------------------------------------- idempotence

    public function test_replaying_a_reset_changes_nothing(): void
    {
        $this->fakePaintStorage();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);
        $at = CarbonImmutable::parse('2026-08-07 10:00:00');

        $this->erase($bearer, 'coyote-2026', 0, $at)->assertOk();
        $revision = BookProgress::query()->sole()->revision;

        $this->erase($bearer, 'coyote-2026', 0, $at)
            ->assertOk()
            ->assertJsonPath('picture_erased', false)
            ->assertJsonPath('revision', $revision);

        $this->assertSame($revision, BookProgress::query()->sole()->revision);
    }

    public function test_an_older_reset_never_walks_the_clock_back(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $later = CarbonImmutable::parse('2026-08-07 12:00:00');
        $this->erase($bearer, 'coyote-2026', 0, $later)->assertOk();
        $this->erase($bearer, 'coyote-2026', 0, CarbonImmutable::parse('2026-08-07 08:00:00'))->assertOk();

        $this->assertSame(
            $later->format('Y-m-d H:i:s.u'),
            BookProgress::query()->sole()->erasedPageAt(0)?->format('Y-m-d H:i:s.u'),
        );
    }

    // -------------------------------------------------------------- guards

    public function test_a_reset_stamped_in_the_far_future_is_refused(): void
    {
        $user = User::factory()->create();

        $this->erase(
            $this->issueDeviceToken($user),
            'coyote-2026',
            0,
            CarbonImmutable::now()->addYears(3),
        )->assertStatus(422)->assertJsonPath('error.code', 'PAINT_CLOCK_SKEW');

        $this->assertSame(0, BookProgress::query()->count());
    }

    public function test_a_page_outside_any_book_is_refused(): void
    {
        $user = User::factory()->create();

        $this->erase($this->issueDeviceToken($user), 'coyote-2026', 9999)
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'PAGE_OUT_OF_RANGE');
    }

    public function test_one_childs_reset_does_not_touch_anothers_page(): void
    {
        $this->fakePaintStorage();

        $user = User::factory()->create();
        $child = ChildProfile::factory()->for($user)->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('account'))->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('child'), null, $child->ulid)->assertCreated();

        $this->erase($bearer, 'coyote-2026', 0, null, $child->ulid)->assertOk();

        $this->assertSame(1, PaintLayer::query()->count());
        $this->assertNull(
            BookProgress::query()->whereNull('child_profile_id')->sole()->erasedPageAt(0),
        );
    }

    public function test_a_profile_that_is_not_ours_is_a_404(): void
    {
        $user = User::factory()->create();
        $stranger = ChildProfile::factory()->for(User::factory())->create();

        $this->erase($this->issueDeviceToken($user), 'coyote-2026', 0, null, $stranger->ulid)
            ->assertNotFound();
    }

    public function test_it_needs_the_save_sync_ability(): void
    {
        $user = User::factory()->create();

        $this->erase($this->issueDeviceToken($user, abilities: ['packs:read']), 'coyote-2026', 0)
            ->assertForbidden();
    }
}
