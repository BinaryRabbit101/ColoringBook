<?php

namespace Tests\Feature;

use App\Actions\Accounts\DeleteAccount;
use App\Actions\Profiles\DeleteChildProfile;
use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\User;
use Illuminate\Database\QueryException;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Tests\TestCase;

/**
 * The `book_progress` table's own guarantees — DLC_SERVER.md §5, §4.1.
 *
 * One row per (account, child, book), and a delete that really deletes.
 */
class BookProgressTest extends TestCase
{
    use RefreshDatabase;

    // -------------------------------------------------------- uniqueness

    public function test_a_book_cannot_be_stored_twice_on_one_childs_shelf(): void
    {
        $profile = ChildProfile::factory()->create();

        BookProgress::factory()->forProfile($profile)->create(['book_uid' => 'coyote-2026']);

        $this->expectException(QueryException::class);

        BookProgress::factory()->forProfile($profile)->create(['book_uid' => 'coyote-2026']);
    }

    public function test_a_book_cannot_be_stored_twice_on_the_account_shelf_either(): void
    {
        // The case a plain UNIQUE(user_id, child_profile_id, book_uid) would
        // miss: SQL treats two NULLs as distinct, so without the coalesced
        // `profile_key` column this second insert would be allowed and the
        // account would quietly grow two rows for one book.
        $user = User::factory()->create();

        BookProgress::factory()->for($user)->create([
            'book_uid' => 'coyote-2026',
            'child_profile_id' => null,
        ]);

        $this->expectException(QueryException::class);

        BookProgress::factory()->for($user)->create([
            'book_uid' => 'coyote-2026',
            'child_profile_id' => null,
        ]);
    }

    public function test_the_account_shelf_and_a_childs_shelf_hold_the_same_book_side_by_side(): void
    {
        $user = User::factory()->create();
        $ivy = ChildProfile::factory()->for($user)->create();
        $sam = ChildProfile::factory()->for($user)->create();

        BookProgress::factory()->for($user)->create(['book_uid' => 'coyote-2026', 'child_profile_id' => null]);
        BookProgress::factory()->forProfile($ivy)->create(['book_uid' => 'coyote-2026']);
        BookProgress::factory()->forProfile($sam)->create(['book_uid' => 'coyote-2026']);

        $this->assertDatabaseCount('book_progress', 3);
    }

    public function test_two_accounts_may_each_hold_the_same_book(): void
    {
        BookProgress::factory()->for(User::factory())->create(['book_uid' => 'coyote-2026']);
        BookProgress::factory()->for(User::factory())->create(['book_uid' => 'coyote-2026']);

        $this->assertDatabaseCount('book_progress', 2);
    }

    // ----------------------------------------------------------- cascades

    public function test_deleting_the_account_deletes_its_progress(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create();

        BookProgress::factory()->for($user)->create();
        BookProgress::factory()->forProfile($profile)->create();

        $survivor = BookProgress::factory()->for(User::factory())->create();

        app(DeleteAccount::class)->handle($user);

        $this->assertDatabaseCount('book_progress', 1);
        $this->assertDatabaseHas('book_progress', ['id' => $survivor->id]);
    }

    public function test_deleting_a_child_deletes_that_childs_progress_only(): void
    {
        $user = User::factory()->create();
        $ivy = ChildProfile::factory()->for($user)->create();
        $sam = ChildProfile::factory()->for($user)->create();

        BookProgress::factory()->forProfile($ivy)->create(['book_uid' => 'ivys-book']);
        BookProgress::factory()->forProfile($sam)->create(['book_uid' => 'sams-book']);
        BookProgress::factory()->for($user)->create(['book_uid' => 'shared-book']);

        app(DeleteChildProfile::class)->handle($ivy);

        $this->assertDatabaseCount('book_progress', 2);
        $this->assertDatabaseMissing('book_progress', ['book_uid' => 'ivys-book']);
        $this->assertDatabaseHas('book_progress', ['book_uid' => 'sams-book']);
        $this->assertDatabaseHas('book_progress', ['book_uid' => 'shared-book']);
    }

    public function test_removing_a_child_through_the_api_takes_their_colouring_with_it(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create();

        BookProgress::factory()->forProfile($profile)->create();

        $this->withToken($this->issueDeviceToken($user))
            ->deleteJson("/api/v1/profiles/{$profile->ulid}")
            ->assertNoContent();

        $this->assertDatabaseCount('book_progress', 0);
    }

    public function test_the_foreign_keys_cascade_on_their_own(): void
    {
        // Belt and braces: the actions delete explicitly, but the schema must
        // be correct even for a raw delete (design §4.1 — never a soft delete).
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create();

        BookProgress::factory()->forProfile($profile)->create();
        BookProgress::factory()->for($user)->create();

        DB::table('users')->where('id', $user->id)->delete();

        $this->assertDatabaseCount('book_progress', 0);
    }

    public function test_deleting_a_profile_row_directly_cascades_too(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create();

        BookProgress::factory()->forProfile($profile)->create();
        BookProgress::factory()->for($user)->create(['book_uid' => 'account-book']);

        DB::table('child_profiles')->where('id', $profile->id)->delete();

        $this->assertDatabaseCount('book_progress', 1);
        $this->assertDatabaseHas('book_progress', ['book_uid' => 'account-book']);
    }

    // ------------------------------------------------------------- shapes

    public function test_page_statuses_round_trip_as_a_list(): void
    {
        $progress = BookProgress::factory()->create([
            'page_statuses' => ['complete', 'in_progress', 'untouched'],
        ]);

        $this->assertSame(['complete', 'in_progress', 'untouched'], $progress->fresh()?->pageStatuses());
    }

    public function test_timestamps_keep_their_microseconds(): void
    {
        // The `since` cursor is an `updated_at` comparison; whole seconds would
        // hide a row written later in the same second.
        $this->travelTo(now()->startOfSecond()->addMicroseconds(123456));

        $progress = BookProgress::factory()->create();

        $this->assertSame('123456', $progress->fresh()?->updated_at?->format('u'));
    }
}
