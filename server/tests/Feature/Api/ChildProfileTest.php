<?php

namespace Tests\Feature\Api;

use App\Models\ChildProfile;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Str;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\TestCase;

/**
 * `/api/v1/profiles` — DLC_SERVER.md §11 "Profiles".
 */
class ChildProfileTest extends TestCase
{
    use RefreshDatabase;

    public function test_it_lists_the_accounts_children(): void
    {
        $user = User::factory()->create();
        ChildProfile::factory()->for($user)->create(['nickname' => 'Ivy']);
        ChildProfile::factory()->for(User::factory())->create(['nickname' => 'Someone else']);

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/profiles')
            ->assertOk()
            ->assertJsonCount(1, 'profiles')
            ->assertJsonPath('profiles.0.nickname', 'Ivy');
    }

    public function test_it_creates_a_child(): void
    {
        $user = User::factory()->create();

        $response = $this->withToken($this->issueDeviceToken($user))
            ->postJson('/api/v1/profiles', [
                'nickname' => '  Ivy  ',
                'avatar_index' => 3,
                'default_mode' => 'adult',
            ]);

        $response->assertCreated()
            ->assertJsonPath('profile.nickname', 'Ivy')
            ->assertJsonPath('profile.avatar_index', 3)
            ->assertJsonPath('profile.default_mode', 'adult');

        $profile = ChildProfile::query()->sole();

        $this->assertTrue(Str::isUlid($profile->ulid));
        $this->assertSame($user->id, $profile->user_id);
        $this->assertSame($profile->ulid, $response->json('profile.ulid'));
    }

    public function test_avatar_index_and_mode_have_sensible_defaults(): void
    {
        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->postJson('/api/v1/profiles', ['nickname' => 'Ivy'])
            ->assertCreated()
            ->assertJsonPath('profile.avatar_index', 0)
            ->assertJsonPath('profile.default_mode', 'child');
    }

    /**
     * @return array<string, array{array<string, mixed>, string}>
     */
    public static function invalidProfiles(): array
    {
        return [
            'no nickname' => [[], 'nickname'],
            'blank nickname' => [['nickname' => '   '], 'nickname'],
            'nickname too long' => [['nickname' => str_repeat('a', 200)], 'nickname'],
            'avatar out of range' => [['nickname' => 'Ivy', 'avatar_index' => 999], 'avatar_index'],
            'negative avatar' => [['nickname' => 'Ivy', 'avatar_index' => -1], 'avatar_index'],
            'avatar not an integer' => [['nickname' => 'Ivy', 'avatar_index' => 'blue'], 'avatar_index'],
            'unknown mode' => [['nickname' => 'Ivy', 'default_mode' => 'teenager'], 'default_mode'],
        ];
    }

    /**
     * @param  array<string, mixed>  $payload
     */
    #[DataProvider('invalidProfiles')]
    public function test_it_validates_the_payload(array $payload, string $field): void
    {
        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->postJson('/api/v1/profiles', $payload)
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED')
            ->assertJsonStructure(['error' => ['details' => [$field]]]);

        $this->assertDatabaseCount('child_profiles', 0);
    }

    public function test_the_number_of_children_per_account_is_bounded(): void
    {
        config(['coloringbook.profiles.max_per_account' => 2]);

        $user = User::factory()->create();
        ChildProfile::factory()->count(2)->for($user)->create();

        $this->withToken($this->issueDeviceToken($user))
            ->postJson('/api/v1/profiles', ['nickname' => 'One too many'])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED');

        $this->assertDatabaseCount('child_profiles', 2);
    }

    public function test_it_renames_a_child(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create([
            'nickname' => 'Ivy',
            'avatar_index' => 1,
        ]);

        $this->withToken($this->issueDeviceToken($user))
            ->patchJson("/api/v1/profiles/{$profile->ulid}", ['nickname' => 'Ivy-Rose'])
            ->assertOk()
            ->assertJsonPath('profile.nickname', 'Ivy-Rose')
            // Untouched fields stay put.
            ->assertJsonPath('profile.avatar_index', 1);

        $this->assertSame('Ivy-Rose', $profile->refresh()->nickname);
    }

    public function test_it_rejects_an_invalid_update(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create(['nickname' => 'Ivy']);

        $this->withToken($this->issueDeviceToken($user))
            ->patchJson("/api/v1/profiles/{$profile->ulid}", ['default_mode' => 'wizard'])
            ->assertStatus(422);

        $this->assertSame('Ivy', $profile->refresh()->nickname);
    }

    public function test_it_deletes_a_child(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create();

        $this->withToken($this->issueDeviceToken($user))
            ->deleteJson("/api/v1/profiles/{$profile->ulid}")
            ->assertNoContent();

        $this->assertDatabaseCount('child_profiles', 0);
    }

    public function test_another_accounts_child_is_simply_not_found(): void
    {
        $user = User::factory()->create();
        $stranger = ChildProfile::factory()->for(User::factory())->create();

        $bearer = $this->issueDeviceToken($user);

        $this->withToken($bearer)
            ->patchJson("/api/v1/profiles/{$stranger->ulid}", ['nickname' => 'Mine now'])
            ->assertNotFound()
            ->assertJsonPath('error.code', 'NOT_FOUND');

        $this->withToken($bearer)
            ->deleteJson("/api/v1/profiles/{$stranger->ulid}")
            ->assertNotFound();

        $this->assertDatabaseCount('child_profiles', 1);
    }

    public function test_every_profile_route_needs_the_save_sync_ability(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create();
        $bearer = $this->issueDeviceToken($user, abilities: ['entitlements:read']);

        $this->withToken($bearer)->getJson('/api/v1/profiles')->assertForbidden();
        $this->withToken($bearer)->postJson('/api/v1/profiles', ['nickname' => 'Ivy'])->assertForbidden();
        $this->withToken($bearer)->patchJson("/api/v1/profiles/{$profile->ulid}", ['nickname' => 'Ivy'])->assertForbidden();
        $this->withToken($bearer)->deleteJson("/api/v1/profiles/{$profile->ulid}")->assertForbidden();

        $this->assertDatabaseCount('child_profiles', 1);
    }

    public function test_every_profile_route_needs_a_token(): void
    {
        $profile = ChildProfile::factory()->create();

        $this->getJson('/api/v1/profiles')->assertUnauthorized();
        $this->postJson('/api/v1/profiles', ['nickname' => 'Ivy'])->assertUnauthorized();
        $this->patchJson("/api/v1/profiles/{$profile->ulid}", ['nickname' => 'Ivy'])->assertUnauthorized();
        $this->deleteJson("/api/v1/profiles/{$profile->ulid}")->assertUnauthorized();
    }
}
