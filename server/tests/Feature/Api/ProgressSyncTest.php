<?php

namespace Tests\Feature\Api;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\User;
use App\Services\ProgressMerge;
use App\Services\ProgressState;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\TestCase;

/**
 * `/api/v1/sync/progress` — DLC_SERVER.md §11 "Sync" and §6.
 */
class ProgressSyncTest extends TestCase
{
    use RefreshDatabase;

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
        array $statuses = ['untouched', 'untouched'],
        int $furthest = 0,
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

    // ------------------------------------------------------------ pulling

    public function test_it_returns_the_account_shelf(): void
    {
        $user = User::factory()->create();

        BookProgress::factory()->for($user)->create([
            'book_uid' => 'coyote-2026',
            'revision' => 3,
            'current_page_index' => 1,
            'page_statuses' => ['complete', 'in_progress'],
            'furthest_page_index' => 1,
        ]);

        $response = $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/sync/progress');

        $response->assertOk()
            ->assertJsonCount(1, 'books')
            ->assertJsonPath('books.0.book_uid', 'coyote-2026')
            ->assertJsonPath('books.0.revision', 3)
            ->assertJsonPath('books.0.current_page_index', 1)
            ->assertJsonPath('books.0.page_statuses', ['complete', 'in_progress'])
            ->assertJsonPath('books.0.furthest_page_index', 1)
            ->assertJsonStructure([
                'books' => [['book_uid', 'revision', 'current_page_index', 'page_statuses', 'furthest_page_index', 'client_updated_at']],
                'server_time',
            ]);
    }

    public function test_another_accounts_shelf_is_invisible(): void
    {
        $user = User::factory()->create();
        BookProgress::factory()->for(User::factory())->create(['book_uid' => 'coyote-2026']);

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/sync/progress')
            ->assertOk()
            ->assertJsonCount(0, 'books');
    }

    public function test_a_profile_and_the_account_have_separate_shelves(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create();

        BookProgress::factory()->for($user)->create(['book_uid' => 'account-book']);
        BookProgress::factory()->forProfile($profile)->create(['book_uid' => 'ivys-book']);

        $bearer = $this->issueDeviceToken($user);

        $this->withToken($bearer)
            ->getJson('/api/v1/sync/progress')
            ->assertOk()
            ->assertJsonCount(1, 'books')
            ->assertJsonPath('books.0.book_uid', 'account-book');

        $this->withToken($bearer)
            ->getJson("/api/v1/sync/progress?profile={$profile->ulid}")
            ->assertOk()
            ->assertJsonCount(1, 'books')
            ->assertJsonPath('books.0.book_uid', 'ivys-book');
    }

    /**
     * @return array<string, array{string}>
     */
    public static function unusableProfiles(): array
    {
        return [
            'not a ulid at all' => ['nonsense'],
            'a well-formed ulid nobody owns' => ['01JZZZZZZZZZZZZZZZZZZZZZZZ'],
        ];
    }

    #[DataProvider('unusableProfiles')]
    public function test_an_unusable_profile_is_a_404(string $ulid): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->withToken($bearer)
            ->getJson("/api/v1/sync/progress?profile={$ulid}")
            ->assertNotFound()
            ->assertJsonPath('error.code', 'NOT_FOUND');

        $this->withToken($bearer)
            ->putJson('/api/v1/sync/progress', ['profile' => $ulid, 'books' => [$this->push()]])
            ->assertNotFound()
            ->assertJsonPath('error.code', 'NOT_FOUND');

        $this->assertDatabaseCount('book_progress', 0);
    }

    public function test_another_accounts_profile_is_a_404_not_a_403(): void
    {
        $user = User::factory()->create();
        $stranger = ChildProfile::factory()->for(User::factory())->create();

        $this->withToken($this->issueDeviceToken($user))
            ->getJson("/api/v1/sync/progress?profile={$stranger->ulid}")
            ->assertNotFound()
            ->assertJsonPath('error.code', 'NOT_FOUND');
    }

    public function test_the_since_cursor_returns_only_what_changed(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));
        $this->withToken($bearer)
            ->putJson('/api/v1/sync/progress', ['books' => [$this->push('first-book')]])
            ->assertOk();

        $cursor = $this->withToken($bearer)->getJson('/api/v1/sync/progress')
            ->assertOk()
            ->assertJsonCount(1, 'books')
            ->json('server_time');

        $this->assertIsString($cursor);

        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:05:00'));
        $this->withToken($bearer)
            ->putJson('/api/v1/sync/progress', ['books' => [$this->push('second-book')]])
            ->assertOk();

        $this->withToken($bearer)
            ->getJson('/api/v1/sync/progress?since='.urlencode($cursor))
            ->assertOk()
            ->assertJsonCount(1, 'books')
            ->assertJsonPath('books.0.book_uid', 'second-book');
    }

    public function test_the_cursor_does_not_lose_a_row_written_in_the_same_second(): void
    {
        // The reason book_progress keeps microsecond timestamps: at whole-second
        // resolution the second write here would be invisible forever.
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00.100000'));
        $this->withToken($bearer)
            ->putJson('/api/v1/sync/progress', ['books' => [$this->push('first-book')]])
            ->assertOk();

        $cursor = $this->withToken($bearer)->getJson('/api/v1/sync/progress')->json('server_time');
        $this->assertIsString($cursor);

        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00.900000'));
        $this->withToken($bearer)
            ->putJson('/api/v1/sync/progress', ['books' => [$this->push('second-book')]])
            ->assertOk();

        $this->withToken($bearer)
            ->getJson('/api/v1/sync/progress?since='.urlencode($cursor))
            ->assertOk()
            ->assertJsonCount(1, 'books')
            ->assertJsonPath('books.0.book_uid', 'second-book');
    }

    public function test_no_cursor_means_the_whole_shelf(): void
    {
        $user = User::factory()->create();
        BookProgress::factory()->count(3)->for($user)->create();

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/sync/progress')
            ->assertOk()
            ->assertJsonCount(3, 'books');
    }

    public function test_an_unparseable_cursor_is_rejected(): void
    {
        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/sync/progress?since=whenever')
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED');
    }

    // ------------------------------------------------------------ pushing

    public function test_a_new_book_is_created_at_revision_one(): void
    {
        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [$this->push('coyote-2026', 0, 1, ['complete', 'in_progress'], 1)],
            ])
            ->assertOk()
            ->assertJsonPath('results.0.book_uid', 'coyote-2026')
            ->assertJsonPath('results.0.revision', 1)
            ->assertJsonPath('results.0.conflict', false)
            ->assertJsonMissingPath('results.0.server');

        $progress = BookProgress::query()->sole();

        $this->assertSame($user->id, $progress->user_id);
        $this->assertNull($progress->child_profile_id);
        $this->assertSame(1, $progress->revision);
        $this->assertSame(['complete', 'in_progress'], $progress->pageStatuses());
        $this->assertSame(1, $progress->current_page_index);
    }

    public function test_a_push_is_merged_into_what_the_server_already_has(): void
    {
        $user = User::factory()->create();
        $progress = BookProgress::factory()->for($user)->create([
            'book_uid' => 'coyote-2026',
            'revision' => 1,
            'current_page_index' => 0,
            'page_statuses' => ['complete', 'untouched', 'untouched'],
            'furthest_page_index' => 0,
            'client_updated_at' => CarbonImmutable::parse('2026-08-06 12:00:00'),
        ]);

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [$this->push(
                    'coyote-2026',
                    baseRevision: 1,
                    current: 2,
                    statuses: ['untouched', 'in_progress'],
                    furthest: 2,
                    at: '2026-08-07T12:00:00+00:00',
                )],
            ])
            ->assertOk()
            ->assertJsonPath('results.0.revision', 2)
            ->assertJsonPath('results.0.conflict', false);

        $progress->refresh();

        // Page 0 stays complete though the newer device called it untouched;
        // page 1 climbs; page 2 survives the shorter incoming array.
        $this->assertSame(['complete', 'in_progress', 'untouched'], $progress->pageStatuses());
        $this->assertSame(2, $progress->current_page_index);
        $this->assertSame(2, $progress->furthest_page_index);
        $this->assertSame(2, $progress->revision);
    }

    public function test_pushing_what_the_server_already_has_is_free(): void
    {
        $user = User::factory()->create();
        $at = CarbonImmutable::parse('2026-08-06 12:00:00');

        $progress = BookProgress::factory()->for($user)->create([
            'book_uid' => 'coyote-2026',
            'revision' => 4,
            'current_page_index' => 1,
            'page_statuses' => ['complete', 'in_progress'],
            'furthest_page_index' => 1,
            'client_updated_at' => $at,
        ]);

        $updatedAt = $progress->updated_at;

        $this->travelTo(CarbonImmutable::parse('2026-08-09 12:00:00'));

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [$this->push('coyote-2026', 4, 1, ['complete', 'in_progress'], 1, $at->toIso8601String())],
            ])
            ->assertOk()
            // The revision stands: nothing changed, so nothing was written and
            // no other device is woken up through the `since` cursor.
            ->assertJsonPath('results.0.revision', 4)
            ->assertJsonPath('results.0.conflict', false);

        $progress->refresh();

        $this->assertSame(4, $progress->revision);
        $this->assertEquals($updatedAt, $progress->updated_at);
    }

    public function test_a_stale_base_revision_conflicts_without_writing(): void
    {
        $user = User::factory()->create();
        $progress = BookProgress::factory()->for($user)->create([
            'book_uid' => 'coyote-2026',
            'revision' => 7,
            'current_page_index' => 3,
            'page_statuses' => ['complete', 'complete'],
            'furthest_page_index' => 3,
        ]);

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [$this->push('coyote-2026', baseRevision: 2, statuses: ['in_progress', 'untouched'])],
            ])
            ->assertOk()
            ->assertJsonPath('results.0.book_uid', 'coyote-2026')
            ->assertJsonPath('results.0.conflict', true)
            ->assertJsonPath('results.0.revision', 7)
            // The full server state rides along, so the device can merge and
            // retry without a second round trip.
            ->assertJsonPath('results.0.server.revision', 7)
            ->assertJsonPath('results.0.server.page_statuses', ['complete', 'complete'])
            ->assertJsonPath('results.0.server.current_page_index', 3)
            ->assertJsonPath('results.0.server.furthest_page_index', 3);

        $progress->refresh();

        $this->assertSame(7, $progress->revision);
        $this->assertSame(['complete', 'complete'], $progress->pageStatuses());
    }

    public function test_one_conflicted_book_does_not_hold_up_the_rest_of_the_shelf(): void
    {
        $user = User::factory()->create();
        BookProgress::factory()->for($user)->create(['book_uid' => 'stale-book', 'revision' => 5]);

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [
                    $this->push('stale-book', baseRevision: 1),
                    $this->push('fresh-book', baseRevision: 0),
                ],
            ])
            ->assertOk()
            ->assertJsonPath('results.0.conflict', true)
            ->assertJsonPath('results.1.conflict', false)
            ->assertJsonPath('results.1.revision', 1);

        $this->assertDatabaseHas('book_progress', ['book_uid' => 'fresh-book', 'revision' => 1]);
        $this->assertDatabaseHas('book_progress', ['book_uid' => 'stale-book', 'revision' => 5]);
    }

    public function test_two_devices_converge_after_a_conflict_and_one_retry(): void
    {
        // The whole protocol of §6.3, end to end.
        $user = User::factory()->create();
        $deviceA = $this->issueDeviceToken($user, 'device-a');
        $deviceB = $this->issueDeviceToken($user, 'device-b');

        // Both devices start from the same synced state.
        $this->withToken($deviceA)
            ->putJson('/api/v1/sync/progress', [
                'books' => [$this->push('coyote-2026', 0, 0, ['untouched', 'untouched'], 0, '2026-08-06T12:00:00+00:00')],
            ])
            ->assertOk()
            ->assertJsonPath('results.0.revision', 1);

        // A finishes page 0 and gets there first.
        $this->withToken($deviceA)
            ->putJson('/api/v1/sync/progress', [
                'books' => [$this->push('coyote-2026', 1, 0, ['complete', 'untouched'], 0, '2026-08-06T12:01:00+00:00')],
            ])
            ->assertOk()
            ->assertJsonPath('results.0.revision', 2);

        // B was offline meanwhile and finished page 1. Its base_revision is stale.
        $bPush = $this->push('coyote-2026', 1, 1, ['untouched', 'complete'], 1, '2026-08-06T12:02:00+00:00');

        $conflict = $this->withToken($deviceB)
            ->putJson('/api/v1/sync/progress', ['books' => [$bPush]])
            ->assertOk()
            ->assertJsonPath('results.0.conflict', true)
            ->json('results.0.server');

        $this->assertIsArray($conflict);

        // B runs the identical merge rule over the server state it was handed,
        // then retries that one book at the revision the server named.
        $merged = (new ProgressMerge)->merge(
            new ProgressState(
                (int) $conflict['current_page_index'],
                array_values(array_map(strval(...), (array) $conflict['page_statuses'])),
                (int) $conflict['furthest_page_index'],
                CarbonImmutable::parse((string) $conflict['client_updated_at']),
            ),
            new ProgressState(1, ['untouched', 'complete'], 1, CarbonImmutable::parse('2026-08-06T12:02:00+00:00')),
        );

        $this->withToken($deviceB)
            ->putJson('/api/v1/sync/progress', [
                'books' => [[
                    'book_uid' => 'coyote-2026',
                    'base_revision' => (int) $conflict['revision'],
                    'current_page_index' => $merged->currentPageIndex,
                    'page_statuses' => $merged->pageStatuses,
                    'furthest_page_index' => $merged->furthestPageIndex,
                    'client_updated_at' => $merged->clientUpdatedAt->toIso8601String(),
                ]],
            ])
            ->assertOk()
            ->assertJsonPath('results.0.conflict', false)
            ->assertJsonPath('results.0.revision', 3);

        // Nothing either child coloured was lost, and both devices now agree.
        $this->withToken($deviceA)
            ->getJson('/api/v1/sync/progress')
            ->assertOk()
            ->assertJsonPath('books.0.page_statuses', ['complete', 'complete'])
            ->assertJsonPath('books.0.current_page_index', 1)
            ->assertJsonPath('books.0.furthest_page_index', 1)
            ->assertJsonPath('books.0.revision', 3);
    }

    public function test_a_push_lands_on_the_named_profiles_shelf(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create();

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'profile' => $profile->ulid,
                'books' => [$this->push('coyote-2026')],
            ])
            ->assertOk();

        $this->assertDatabaseHas('book_progress', [
            'book_uid' => 'coyote-2026',
            'child_profile_id' => $profile->id,
        ]);
        $this->assertDatabaseMissing('book_progress', [
            'book_uid' => 'coyote-2026',
            'child_profile_id' => null,
        ]);
    }

    public function test_the_same_book_on_two_shelves_is_two_independent_rows(): void
    {
        $user = User::factory()->create();
        $ivy = ChildProfile::factory()->for($user)->create();
        $sam = ChildProfile::factory()->for($user)->create();
        $bearer = $this->issueDeviceToken($user);

        foreach ([null, $ivy->ulid, $sam->ulid] as $profile) {
            $payload = ['books' => [$this->push('coyote-2026')]];

            if ($profile !== null) {
                $payload['profile'] = $profile;
            }

            $this->withToken($bearer)
                ->putJson('/api/v1/sync/progress', $payload)
                ->assertOk()
                ->assertJsonPath('results.0.revision', 1);
        }

        $this->assertDatabaseCount('book_progress', 3);
    }

    public function test_a_batch_pushes_the_whole_shelf_at_once(): void
    {
        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [
                    $this->push('coyote-2026'),
                    $this->push('fox-2026'),
                    $this->push('badger-2026'),
                ],
            ])
            ->assertOk()
            ->assertJsonCount(3, 'results');

        $this->assertDatabaseCount('book_progress', 3);
    }

    public function test_a_far_future_client_clock_is_clamped(): void
    {
        $user = User::factory()->create();
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [$this->push('coyote-2026', at: '2031-01-01T00:00:00+00:00')],
            ])
            ->assertOk();

        $progress = BookProgress::query()->sole();

        // Clamped to now, not rejected: a wrong clock must never stop a child's
        // colouring being saved, and left alone it would win every merge for
        // the next five years.
        $this->assertTrue($progress->client_updated_at->equalTo(CarbonImmutable::parse('2026-08-06 12:00:00')));
    }

    public function test_a_clock_inside_the_skew_window_is_left_alone(): void
    {
        $user = User::factory()->create();
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [$this->push('coyote-2026', at: '2026-08-06T20:00:00+00:00')],
            ])
            ->assertOk();

        $this->assertTrue(
            BookProgress::query()->sole()->client_updated_at
                ->equalTo(CarbonImmutable::parse('2026-08-06 20:00:00')),
        );
    }

    public function test_an_old_client_clock_is_never_touched(): void
    {
        $user = User::factory()->create();
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [$this->push('coyote-2026', at: '2020-01-01T00:00:00+00:00')],
            ])
            ->assertOk();

        $this->assertTrue(
            BookProgress::query()->sole()->client_updated_at
                ->equalTo(CarbonImmutable::parse('2020-01-01 00:00:00')),
        );
    }

    // --------------------------------------------------------- validation

    /**
     * @return array<string, array{array<string, mixed>, string}>
     */
    public static function invalidBooks(): array
    {
        return [
            'unknown status' => [['page_statuses' => ['finished']], 'books.0.page_statuses.0'],
            'status is not a string' => [['page_statuses' => [3]], 'books.0.page_statuses.0'],
            'statuses missing' => [['page_statuses' => null], 'books.0.page_statuses'],
            'statuses not an array' => [['page_statuses' => 'complete'], 'books.0.page_statuses'],
            'no book_uid' => [['book_uid' => null], 'books.0.book_uid'],
            'book_uid with a slash' => [['book_uid' => 'res://books/coyote'], 'books.0.book_uid'],
            'book_uid too long' => [['book_uid' => str_repeat('a', 65)], 'books.0.book_uid'],
            'no base_revision' => [['base_revision' => null], 'books.0.base_revision'],
            'negative base_revision' => [['base_revision' => -1], 'books.0.base_revision'],
            'base_revision not an integer' => [['base_revision' => 'one'], 'books.0.base_revision'],
            'negative current page' => [['current_page_index' => -1], 'books.0.current_page_index'],
            'negative furthest page' => [['furthest_page_index' => -1], 'books.0.furthest_page_index'],
            'no client clock' => [['client_updated_at' => null], 'books.0.client_updated_at'],
            'unparseable client clock' => [['client_updated_at' => 'yesterday-ish'], 'books.0.client_updated_at'],
        ];
    }

    /**
     * @param  array<string, mixed>  $override
     */
    #[DataProvider('invalidBooks')]
    public function test_it_validates_each_book_strictly(array $override, string $field): void
    {
        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [array_merge($this->push(), $override)],
            ])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED')
            ->assertJsonStructure(['error' => ['details' => [$field]]]);

        $this->assertDatabaseCount('book_progress', 0);
    }

    public function test_the_same_book_cannot_be_sent_twice_in_one_request(): void
    {
        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [$this->push('coyote-2026'), $this->push('coyote-2026')],
            ])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED');

        $this->assertDatabaseCount('book_progress', 0);
    }

    public function test_an_empty_or_missing_book_list_is_rejected(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->withToken($bearer)->putJson('/api/v1/sync/progress', [])->assertStatus(422);
        $this->withToken($bearer)->putJson('/api/v1/sync/progress', ['books' => []])->assertStatus(422);
    }

    public function test_the_batch_is_bounded(): void
    {
        config(['coloringbook.sync.max_books_per_request' => 2]);

        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [$this->push('a-book'), $this->push('b-book'), $this->push('c-book')],
            ])
            ->assertStatus(422)
            ->assertJsonStructure(['error' => ['details' => ['books']]]);

        $this->assertDatabaseCount('book_progress', 0);
    }

    public function test_a_book_cannot_carry_an_unbounded_number_of_pages(): void
    {
        config(['coloringbook.sync.max_pages_per_book' => 3]);

        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->putJson('/api/v1/sync/progress', [
                'books' => [$this->push(statuses: array_fill(0, 4, 'untouched'))],
            ])
            ->assertStatus(422)
            ->assertJsonStructure(['error' => ['details' => ['books.0.page_statuses']]]);
    }

    // --------------------------------------------------------------- auth

    public function test_both_routes_need_a_token(): void
    {
        $this->getJson('/api/v1/sync/progress')->assertUnauthorized();
        $this->putJson('/api/v1/sync/progress', ['books' => [$this->push()]])->assertUnauthorized();
    }

    public function test_both_routes_need_the_save_sync_ability(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user, abilities: ['entitlements:read', 'packs:download']);

        $this->withToken($bearer)->getJson('/api/v1/sync/progress')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'MISSING_ABILITY');

        $this->withToken($bearer)->putJson('/api/v1/sync/progress', ['books' => [$this->push()]])
            ->assertForbidden()
            ->assertJsonPath('error.code', 'MISSING_ABILITY');

        $this->assertDatabaseCount('book_progress', 0);
    }

    public function test_a_revoked_token_stops_syncing(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->withToken($bearer)->getJson('/api/v1/sync/progress')->assertOk();

        $user->tokens()->delete();
        $this->forgetResolvedGuards();

        $this->withToken($bearer)->getJson('/api/v1/sync/progress')->assertUnauthorized();
    }
}
