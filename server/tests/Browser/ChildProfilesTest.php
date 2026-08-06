<?php

namespace Tests\Browser;

use App\Models\ChildProfile;
use App\Models\User;
use Laravel\Dusk\Browser;
use Tests\DuskTestCase;

/**
 * The children page — WP8.
 *
 * A nickname and an avatar index is the entire record of a child
 * (DLC_SERVER.md §4.1), so there is not much surface here. What there is worth
 * proving in a browser is the **two-step remove**: removing a child takes
 * everything they have coloured with them, so the destructive form is not even
 * rendered until a first click asks for it. That gate is client-side state in
 * `Profiles.vue` and exists nowhere in the HTTP layer — a route test cannot
 * see it.
 *
 * A nickname is only ever an `<input>` value on this page, never page text, so
 * "did that save?" is answered by the flash toast (`Inertia::flash('toast')`,
 * rendered by `<Toaster />`) rather than by looking for the name.
 */
class ChildProfilesTest extends DuskTestCase
{
    public function test_a_parent_adds_a_child(): void
    {
        $user = User::factory()->create();

        $this->browse(function (Browser $browser) use ($user): void {
            $browser->loginAs($user)
                ->visit('/settings/profiles')
                ->waitForText('No profiles yet')
                ->type('#new-nickname', 'Ivy')
                ->select('#new-avatar', '3')
                ->select('#new-mode', 'child')
                ->click('[data-test="add-profile-button"]')
                ->waitForText('Profile added.')
                ->waitUntilMissingText('No profiles yet');
        });

        $profile = ChildProfile::query()->sole();

        $this->assertSame('Ivy', $profile->nickname);
        $this->assertSame(3, $profile->avatar_index);
        $this->assertSame('child', $profile->default_mode);
        $this->assertTrue($profile->user->is($user));
    }

    public function test_a_parent_renames_a_child(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create(['nickname' => 'Ivy']);

        $this->browse(function (Browser $browser) use ($user, $profile): void {
            $browser->loginAs($user)
                ->visit('/settings/profiles')
                ->waitFor("#nickname-{$profile->ulid}")
                ->assertInputValue("#nickname-{$profile->ulid}", 'Ivy')
                ->type("#nickname-{$profile->ulid}", 'Ivy Rose')
                ->click("[data-test=\"save-profile-{$profile->ulid}\"]")
                ->waitForText('Profile updated.');
        });

        $this->assertSame('Ivy Rose', $profile->refresh()->nickname);
    }

    public function test_removing_a_child_takes_two_clicks(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create(['nickname' => 'Ivy']);

        $this->browse(function (Browser $browser) use ($user, $profile): void {
            $browser->loginAs($user)
                ->visit('/settings/profiles')
                ->waitFor("[data-test=\"remove-profile-{$profile->ulid}\"]")
                // The button that actually removes anything is not on the page
                // yet, so a mis-click cannot delete a child's colouring.
                ->assertMissing("[data-test=\"confirm-remove-profile-{$profile->ulid}\"]")
                ->click("[data-test=\"remove-profile-{$profile->ulid}\"]")
                ->waitForText('Remove Ivy and everything they have coloured?')
                ->assertPresent("[data-test=\"confirm-remove-profile-{$profile->ulid}\"]");
        });

        // Still there: asking is not doing.
        $this->assertDatabaseCount('child_profiles', 1);
    }

    public function test_confirming_the_second_click_removes_the_child(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create(['nickname' => 'Ivy']);

        $this->browse(function (Browser $browser) use ($user, $profile): void {
            $browser->loginAs($user)
                ->visit('/settings/profiles')
                ->waitFor("[data-test=\"remove-profile-{$profile->ulid}\"]")
                ->click("[data-test=\"remove-profile-{$profile->ulid}\"]")
                ->waitFor("[data-test=\"confirm-remove-profile-{$profile->ulid}\"]")
                ->click("[data-test=\"confirm-remove-profile-{$profile->ulid}\"]")
                ->waitForText('Profile removed.')
                ->waitForText('No profiles yet');
        });

        $this->assertDatabaseCount('child_profiles', 0);
    }

    public function test_cancelling_puts_the_confirmation_away_again(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create(['nickname' => 'Ivy']);

        $this->browse(function (Browser $browser) use ($user, $profile): void {
            $browser->loginAs($user)
                ->visit('/settings/profiles')
                ->waitFor("[data-test=\"remove-profile-{$profile->ulid}\"]")
                ->click("[data-test=\"remove-profile-{$profile->ulid}\"]")
                ->waitFor("[data-test=\"confirm-remove-profile-{$profile->ulid}\"]")
                ->clickAtXPath("//button[normalize-space()='Cancel']")
                ->waitUntilMissing("[data-test=\"confirm-remove-profile-{$profile->ulid}\"]")
                ->assertPresent("[data-test=\"remove-profile-{$profile->ulid}\"]");
        });

        $this->assertDatabaseCount('child_profiles', 1);
    }

    public function test_the_guard_rail_on_profiles_per_account_is_shown_in_the_form(): void
    {
        $max = (int) config('coloringbook.profiles.max_per_account');
        $user = User::factory()->create();

        ChildProfile::factory()->count($max)->for($user)->create();

        $this->browse(function (Browser $browser) use ($user, $max): void {
            $browser->loginAs($user)
                ->visit('/settings/profiles')
                ->waitFor('#new-nickname')
                ->type('#new-nickname', 'One Too Many')
                ->click('[data-test="add-profile-button"]')
                ->waitForText("This account already has the maximum of {$max} profiles.");
        });

        $this->assertDatabaseCount('child_profiles', $max);
    }
}
