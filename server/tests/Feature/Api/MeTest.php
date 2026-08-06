<?php

namespace Tests\Feature\Api;

use App\Models\ChildProfile;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

/**
 * `GET /api/v1/me` — the account screen in one round trip (DLC_SERVER.md §11).
 */
class MeTest extends TestCase
{
    use RefreshDatabase;

    public function test_it_returns_the_user_their_children_and_their_devices(): void
    {
        $user = User::factory()->create();
        ChildProfile::factory()->for($user)->create(['nickname' => 'Ivy']);
        $bearer = $this->issueDeviceToken($user, 'device-uid-tablet');

        $response = $this->withToken($bearer)->getJson('/api/v1/me');

        $response->assertOk()
            ->assertJsonPath('user.ulid', $user->ulid)
            ->assertJsonPath('user.email', $user->email)
            ->assertJsonPath('profiles.0.nickname', 'Ivy')
            ->assertJsonPath('devices.0.device_uid', 'device-uid-tablet')
            ->assertJsonPath('devices.0.is_signed_in', true)
            ->assertJsonCount(1, 'profiles')
            ->assertJsonCount(1, 'devices');
    }

    public function test_it_never_exposes_numeric_keys_or_the_password(): void
    {
        $user = User::factory()->create();
        ChildProfile::factory()->for($user)->create();

        $response = $this->withToken($this->issueDeviceToken($user))->getJson('/api/v1/me');

        $this->assertArrayNotHasKey('id', $response->json('user'));
        $this->assertArrayNotHasKey('password', $response->json('user'));
        $this->assertArrayNotHasKey('id', $response->json('profiles.0'));
        $this->assertArrayNotHasKey('user_id', $response->json('profiles.0'));
        $this->assertArrayNotHasKey('id', $response->json('devices.0'));
    }

    public function test_it_only_ever_shows_the_callers_own_household(): void
    {
        $user = User::factory()->create();
        $stranger = User::factory()->create();
        ChildProfile::factory()->for($stranger)->create(['nickname' => 'Not yours']);

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/me')
            ->assertOk()
            ->assertJsonCount(0, 'profiles');
    }

    public function test_it_requires_a_token(): void
    {
        $this->getJson('/api/v1/me')
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'UNAUTHENTICATED');
    }

    public function test_it_requires_the_save_sync_ability(): void
    {
        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user, abilities: ['packs:download']))
            ->getJson('/api/v1/me')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'MISSING_ABILITY');
    }

    public function test_a_revoked_device_loses_access_immediately(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user, 'device-uid-tablet');

        $this->withToken($bearer)->getJson('/api/v1/me')->assertOk();

        $user->tokens()->where('name', 'device-uid-tablet')->delete();

        $this->forgetResolvedGuards()
            ->withToken($bearer)->getJson('/api/v1/me')
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'UNAUTHENTICATED');
    }
}
