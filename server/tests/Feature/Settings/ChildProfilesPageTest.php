<?php

namespace Tests\Feature\Settings;

use App\Models\ChildProfile;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

/**
 * The parent dashboard's children page — session auth, same actions and same
 * validation rules as the API.
 */
class ChildProfilesPageTest extends TestCase
{
    use RefreshDatabase;

    public function test_the_page_lists_the_accounts_children(): void
    {
        $user = User::factory()->create();
        ChildProfile::factory()->for($user)->create(['nickname' => 'Ivy']);
        ChildProfile::factory()->for(User::factory())->create(['nickname' => 'Someone else']);

        $this->actingAs($user)
            ->get(route('child-profiles.edit'))
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('settings/Profiles')
                ->has('profiles', 1)
                ->where('profiles.0.nickname', 'Ivy')
                ->has('avatarCount')
                ->has('nicknameMax')
                ->has('modes'),
            );
    }

    public function test_the_page_needs_a_signed_in_parent(): void
    {
        $this->get(route('child-profiles.edit'))->assertRedirect(route('login'));
    }

    public function test_a_parent_can_add_a_child(): void
    {
        $user = User::factory()->create();

        $this->actingAs($user)
            ->post(route('child-profiles.store'), [
                'nickname' => 'Ivy',
                'avatar_index' => 2,
                'default_mode' => 'child',
            ])
            ->assertSessionHasNoErrors()
            ->assertRedirect(route('child-profiles.edit'));

        $profile = ChildProfile::query()->sole();

        $this->assertSame('Ivy', $profile->nickname);
        $this->assertSame(2, $profile->avatar_index);
        $this->assertSame($user->id, $profile->user_id);
    }

    public function test_adding_a_child_is_validated(): void
    {
        $user = User::factory()->create();

        $this->actingAs($user)
            ->from(route('child-profiles.edit'))
            ->post(route('child-profiles.store'), ['nickname' => ''])
            ->assertSessionHasErrors('nickname');

        $this->assertDatabaseCount('child_profiles', 0);
    }

    public function test_a_parent_can_rename_a_child(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create(['nickname' => 'Ivy']);

        $this->actingAs($user)
            ->patch(route('child-profiles.update', $profile->ulid), ['nickname' => 'Ivy-Rose'])
            ->assertSessionHasNoErrors()
            ->assertRedirect(route('child-profiles.edit'));

        $this->assertSame('Ivy-Rose', $profile->refresh()->nickname);
    }

    public function test_a_parent_can_remove_a_child(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create();

        $this->actingAs($user)
            ->delete(route('child-profiles.destroy', $profile->ulid))
            ->assertRedirect(route('child-profiles.edit'));

        $this->assertDatabaseCount('child_profiles', 0);
    }

    public function test_a_parent_cannot_touch_another_accounts_child(): void
    {
        $user = User::factory()->create();
        $stranger = ChildProfile::factory()->for(User::factory())->create(['nickname' => 'Ivy']);

        $this->actingAs($user)
            ->patch(route('child-profiles.update', $stranger->ulid), ['nickname' => 'Mine now'])
            ->assertNotFound();

        $this->actingAs($user)
            ->delete(route('child-profiles.destroy', $stranger->ulid))
            ->assertNotFound();

        $this->assertSame('Ivy', $stranger->refresh()->nickname);
    }

    public function test_profiles_are_addressed_by_ulid_not_by_id(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create();

        $this->actingAs($user)
            ->patch(route('child-profiles.update', $profile->id), ['nickname' => 'Nope'])
            ->assertNotFound();
    }
}
