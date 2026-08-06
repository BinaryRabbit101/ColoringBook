<?php

namespace Tests\Feature;

use App\Actions\Accounts\DeleteAccount;
use App\Actions\Profiles\DeleteChildProfile;
use App\Models\ChildProfile;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\PaintsPages;
use Tests\TestCase;

/**
 * Deletion really deletes — pictures included (DLC_SERVER.md §4.1).
 *
 * The rows cascade through foreign keys, but a disk is not part of the FK
 * graph: without an explicit sweep, "delete my account" would leave a child's
 * drawings sitting in `storage/app/private/paint/` forever. That is the whole
 * point of these tests.
 */
class PaintDeletionTest extends TestCase
{
    use PaintsPages, RefreshDatabase;

    /**
     * A page painted twice, so there is a retained blob to sweep as well as a
     * live one.
     */
    private function paintTwice(User $user, string $bearer, ?ChildProfile $profile = null): void
    {
        $at = CarbonImmutable::parse('2026-08-06 09:00:00');

        $this->upload($bearer, 'coyote-2026', 0, $this->png('first'), $at, $profile?->ulid)->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('second'), $at->addHour(), $profile?->ulid)->assertCreated();
    }

    public function test_deleting_the_account_sweeps_every_picture_off_the_disk(): void
    {
        $disk = $this->fakePaintStorage();

        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create();
        $bearer = $this->issueDeviceToken($user);

        $this->paintTwice($user, $bearer);
        $this->paintTwice($user, $bearer, $profile);

        $this->assertNotEmpty($disk->allFiles());
        $this->assertDatabaseCount('paint_layers', 2);
        $this->assertDatabaseCount('retained_paint_layers', 2);

        $this->app->make(DeleteAccount::class)->handle($user);

        $this->assertDatabaseCount('paint_layers', 0);
        $this->assertDatabaseCount('retained_paint_layers', 0);
        $this->assertDatabaseCount('book_progress', 0);
        $this->assertSame([], $disk->allFiles());
        $disk->assertDirectoryEmpty('/');
    }

    public function test_deleting_the_account_leaves_the_neighbours_pictures_alone(): void
    {
        $disk = $this->fakePaintStorage();

        $leaving = User::factory()->create();
        $staying = User::factory()->create();

        $this->paintTwice($leaving, $this->issueDeviceToken($leaving, 'leaving'));
        $this->forgetResolvedGuards();
        $this->paintTwice($staying, $this->issueDeviceToken($staying, 'staying'));

        $this->app->make(DeleteAccount::class)->handle($leaving);

        $disk->assertMissing("{$leaving->ulid}/coyote-2026/page_01.png");
        $disk->assertExists("{$staying->ulid}/coyote-2026/page_01.png");
        $disk->assertExists("{$staying->ulid}/coyote-2026/page_01.1.png");
        $this->assertDatabaseCount('paint_layers', 1);
        $this->assertDatabaseCount('retained_paint_layers', 1);
    }

    public function test_removing_a_child_sweeps_only_their_pictures(): void
    {
        $disk = $this->fakePaintStorage();

        $user = User::factory()->create();
        $ivy = ChildProfile::factory()->for($user)->create();
        $sam = ChildProfile::factory()->for($user)->create();
        $bearer = $this->issueDeviceToken($user);

        $this->paintTwice($user, $bearer);
        $this->paintTwice($user, $bearer, $ivy);
        $this->paintTwice($user, $bearer, $sam);

        $this->app->make(DeleteChildProfile::class)->handle($ivy);

        $disk->assertMissing("{$user->ulid}/{$ivy->ulid}/coyote-2026/page_01.png");
        $disk->assertMissing("{$user->ulid}/{$ivy->ulid}/coyote-2026/page_01.1.png");

        // The account's own shelf and the other child's are untouched.
        $disk->assertExists("{$user->ulid}/coyote-2026/page_01.png");
        $disk->assertExists("{$user->ulid}/{$sam->ulid}/coyote-2026/page_01.png");

        $this->assertDatabaseCount('paint_layers', 2);
        $this->assertDatabaseCount('retained_paint_layers', 2);
        $this->assertDatabaseCount('child_profiles', 1);
    }

    public function test_the_dashboards_delete_account_button_takes_the_pictures_too(): void
    {
        $disk = $this->fakePaintStorage();

        $user = User::factory()->create(['password' => bcrypt('password'), 'email_verified_at' => now()]);
        $this->paintTwice($user, $this->issueDeviceToken($user));

        $this->useSessionGuard()
            ->actingAs($user)
            ->delete(route('profile.destroy'), ['password' => 'password'])
            ->assertRedirect('/');

        $this->assertDatabaseCount('users', 0);
        $this->assertSame([], $disk->allFiles());
    }
}
