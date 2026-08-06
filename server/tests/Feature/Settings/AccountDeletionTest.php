<?php

namespace Tests\Feature\Settings;

use App\Models\ChildProfile;
use App\Models\Device;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

/**
 * "Account deletion must be self-serve and must actually delete … not
 * soft-delete" — DLC_SERVER.md §4.1.
 */
class AccountDeletionTest extends TestCase
{
    use RefreshDatabase;

    public function test_deleting_the_account_takes_profiles_devices_and_tokens_with_it(): void
    {
        $user = User::factory()->create();
        ChildProfile::factory()->count(2)->for($user)->create();
        $bearer = $this->issueDeviceToken($user, 'device-uid-tablet');

        $survivor = User::factory()->create();
        ChildProfile::factory()->for($survivor)->create();
        $this->issueDeviceToken($survivor, 'device-uid-other-household');

        $this->actingAs($user)
            ->delete(route('profile.destroy'), ['password' => 'password'])
            ->assertSessionHasNoErrors()
            ->assertRedirect('/');

        $this->assertGuest();
        $this->assertNull($user->fresh());

        $this->assertSame(0, ChildProfile::query()->where('user_id', $user->id)->count());
        $this->assertSame(0, Device::query()->where('user_id', $user->id)->count());
        $this->assertDatabaseMissing('personal_access_tokens', ['name' => 'device-uid-tablet']);

        // The token is dead the moment the account is.
        $this->forgetResolvedGuards()->withToken($bearer)->getJson('/api/v1/me')->assertUnauthorized();

        // Nobody else's household was touched.
        $this->assertNotNull($survivor->fresh());
        $this->assertSame(1, ChildProfile::query()->where('user_id', $survivor->id)->count());
        $this->assertSame(1, $survivor->tokens()->count());
    }

    public function test_deletion_requires_the_password(): void
    {
        $user = User::factory()->create();
        ChildProfile::factory()->for($user)->create();
        $this->issueDeviceToken($user);

        $this->actingAs($user)
            ->from(route('profile.edit'))
            ->delete(route('profile.destroy'), ['password' => 'not-the-password'])
            ->assertSessionHasErrors('password');

        $this->assertNotNull($user->fresh());
        $this->assertDatabaseCount('child_profiles', 1);
        $this->assertDatabaseCount('devices', 1);
        $this->assertDatabaseCount('personal_access_tokens', 1);
    }

    public function test_the_foreign_keys_cascade_on_their_own(): void
    {
        // Belt as well as braces: WP2's progress and WP4's paint hang off the
        // same cascade, so the constraints themselves have to be right.
        $user = User::factory()->create();
        ChildProfile::factory()->count(2)->for($user)->create();
        Device::factory()->count(2)->for($user)->create();

        $user->delete();

        $this->assertDatabaseCount('child_profiles', 0);
        $this->assertDatabaseCount('devices', 0);
    }

    public function test_nothing_in_this_schema_soft_deletes(): void
    {
        foreach ([User::class, ChildProfile::class, Device::class] as $model) {
            $this->assertArrayNotHasKey(
                'Illuminate\Database\Eloquent\SoftDeletes',
                class_uses_recursive($model),
                $model.' must not soft-delete (design §4.1).',
            );
        }
    }
}
