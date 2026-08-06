<?php

namespace Tests\Browser;

use App\Models\ChildProfile;
use App\Models\Device;
use App\Models\PaintLayer;
use App\Models\User;
use App\Services\PaintStorage;
use Laravel\Dusk\Browser;
use Tests\Concerns\SeedsBrowserFixtures;
use Tests\DuskTestCase;

/**
 * Deleting the account, from the dialog a parent actually uses — WP8.
 *
 * "Account deletion must be self-serve and must actually delete (progress
 * rows, paint blobs, profiles), not soft-delete" — DLC_SERVER.md §4.1. Both
 * halves are load-bearing: **self-serve** is why this is a button in a dialog
 * rather than a support request, and **actually delete** is why the assertions
 * below go looking for the rows and the files afterwards.
 *
 * The password re-confirmation is the only thing standing between a tablet
 * left unlocked on a sofa and an account that no longer exists.
 */
class AccountDeletionTest extends DuskTestCase
{
    use SeedsBrowserFixtures;

    public function test_the_wrong_password_deletes_nothing(): void
    {
        $user = User::factory()->create();

        $this->browse(function (Browser $browser) use ($user): void {
            $browser->loginAs($user)
                ->visit('/settings/profile')
                ->waitFor('[data-test="delete-user-button"]')
                ->click('[data-test="delete-user-button"]')
                ->waitForText('Are you sure you want to delete your account?')
                ->type('#password', 'not-the-password')
                ->click('[data-test="confirm-delete-user-button"]')
                ->waitForText('The password is incorrect.')
                // Still signed in, still on the settings page.
                ->assertPathIs('/settings/profile');
        });

        $this->assertNotNull($user->fresh());
    }

    public function test_the_dialog_can_be_closed_without_deleting_anything(): void
    {
        $user = User::factory()->create();

        $this->browse(function (Browser $browser) use ($user): void {
            $browser->loginAs($user)
                ->visit('/settings/profile')
                ->waitFor('[data-test="delete-user-button"]')
                ->click('[data-test="delete-user-button"]')
                ->waitForText('Are you sure you want to delete your account?')
                ->clickAtXPath("//button[normalize-space()='Cancel']")
                ->waitUntilMissingText('Are you sure you want to delete your account?')
                ->assertPathIs('/settings/profile');
        });

        $this->assertNotNull($user->fresh());
    }

    public function test_the_right_password_deletes_the_household_and_its_pictures(): void
    {
        $user = User::factory()->create();
        ChildProfile::factory()->count(2)->for($user)->create();
        Device::factory()->for($user)->create(['device_uid' => 'device-uid-tablet']);
        $user->createToken('device-uid-tablet', ['save:sync']);

        $retained = $this->seedContestedPage($user);
        $paintRoot = app(PaintStorage::class);

        $this->assertTrue($paintRoot->disk()->exists($retained->storage_path));

        // A second household, to prove the sweep is not indiscriminate.
        $survivor = User::factory()->create();
        ChildProfile::factory()->for($survivor)->create();

        $this->browse(function (Browser $browser) use ($user): void {
            $browser->loginAs($user)
                ->visit('/settings/profile')
                ->waitFor('[data-test="delete-user-button"]')
                ->click('[data-test="delete-user-button"]')
                ->waitForText('Are you sure you want to delete your account?')
                ->type('#password', 'password')
                ->click('[data-test="confirm-delete-user-button"]')
                // Signed out and dropped on the welcome page.
                ->waitForLocation('/')
                // And really signed out: the dashboard sends them to login.
                ->visit('/dashboard')
                ->waitForLocation('/login');
        });

        // A real hard delete. There is no `deleted_at` in this schema.
        $this->assertNull($user->fresh());
        $this->assertSame(0, ChildProfile::query()->where('user_id', $user->id)->count());
        $this->assertSame(0, Device::query()->where('user_id', $user->id)->count());
        $this->assertDatabaseMissing('personal_access_tokens', ['name' => 'device-uid-tablet']);
        $this->assertSame(0, PaintLayer::query()->count());
        $this->assertDatabaseCount('book_progress', 0);
        $this->assertDatabaseCount('retained_paint_layers', 0);

        // The blobs go too — a disk cannot be rolled back, so they are swept
        // after the transaction commits rather than inside it.
        $this->assertFalse($paintRoot->disk()->exists($retained->storage_path));
        $this->assertFalse($paintRoot->disk()->exists($user->ulid));

        // Nobody else's household was touched.
        $this->assertNotNull($survivor->fresh());
        $this->assertSame(1, ChildProfile::query()->where('user_id', $survivor->id)->count());
    }
}
