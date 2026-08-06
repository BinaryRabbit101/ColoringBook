<?php

namespace Tests\Feature\Api;

use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * `GET /api/v1/entitlements` — the inventory *and* the update check
 * (DLC_SERVER.md §11, §7.3).
 */
class EntitlementIndexTest extends TestCase
{
    use PublishesPacks, RefreshDatabase;

    public function test_it_returns_the_shape_the_design_specifies(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        $user = User::factory()->create();
        Entitlement::factory()->for($user)->for($pack)
            ->source(Entitlement::SOURCE_PROMO)
            ->create(['granted_at' => now()->subDay()]);

        $response = $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/entitlements');

        // A bare array, exactly as §11 writes it.
        $response->assertOk()
            ->assertJsonCount(1)
            ->assertJsonPath('0.pack_slug', 'forest-friends')
            ->assertJsonPath('0.latest_version', 1)
            ->assertJsonPath('0.source', 'promo');

        $this->assertSame(
            ['pack_slug', 'latest_version', 'source', 'granted_at'],
            array_keys((array) $response->json('0')),
        );
    }

    public function test_it_is_the_update_check(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        $user = User::factory()->create();
        Entitlement::factory()->for($user)->for($pack)->create();
        $bearer = $this->issueDeviceToken($user);

        $this->withToken($bearer)->getJson('/api/v1/entitlements')
            ->assertJsonPath('0.latest_version', 1);

        // The pack ships a fix; the same call the client already makes on
        // launch now says "there is a v2" — no extra round trip (§7.3).
        $this->publishFixturePack();

        $this->withToken($bearer)->getJson('/api/v1/entitlements')
            ->assertJsonPath('0.latest_version', 2);
    }

    public function test_an_old_build_is_told_the_newest_release_it_can_run(): void
    {
        $pack = Pack::factory()->create(['slug' => 'forest-friends']);
        PackVersion::factory()->for($pack, 'pack')->version(1)->requiresClient('0.7.0')->create();
        PackVersion::factory()->for($pack, 'pack')->version(2)->requiresClient('0.9.0')->create();

        $user = User::factory()->create();
        Entitlement::factory()->for($user)->for($pack)->create();

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/entitlements?client_version=0.7.5')
            ->assertOk()
            ->assertJsonPath('0.latest_version', 1);
    }

    public function test_revoked_claims_are_absent(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        $user = User::factory()->create();
        Entitlement::factory()->for($user)->for($pack)->revoked()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/entitlements')
            ->assertOk()
            ->assertJsonCount(0);
    }

    public function test_it_only_ever_shows_the_callers_own_claims(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        Entitlement::factory()->for(User::factory())->for($pack)->create();

        $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->getJson('/api/v1/entitlements')
            ->assertOk()
            ->assertJsonCount(0);
    }

    public function test_it_requires_a_token_and_the_entitlements_read_ability(): void
    {
        $this->getJson('/api/v1/entitlements')
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'UNAUTHENTICATED');

        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user, 'tablet', ['save:sync']))
            ->getJson('/api/v1/entitlements')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'MISSING_ABILITY');
    }

    public function test_a_free_pack_appears_only_once_it_has_been_claimed(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack(free: true);

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        // Free is not the same as owned: the list is what the device should
        // have installed, not the catalog in disguise.
        $this->withToken($bearer)->getJson('/api/v1/entitlements')
            ->assertOk()
            ->assertJsonCount(0);

        $this->withToken($bearer)->get('/api/v1/packs/forest-friends/download')->assertRedirect();

        $this->withToken($bearer)->getJson('/api/v1/entitlements')
            ->assertOk()
            ->assertJsonCount(1)
            ->assertJsonPath('0.source', 'free')
            ->assertJsonPath('0.pack_slug', 'forest-friends');
    }
}
