<?php

namespace Tests\Feature\Api;

use App\Models\Device;
use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\AdminsPacks;
use Tests\TestCase;

/**
 * `POST /api/v1/admin/entitlements` — the promo grant, and the un-revoke that
 * WP3 deliberately left unbuilt (§9: "un-revoking is a deliberate admin act").
 *
 * A claim is addressed by `device_uid`: the device is the identity, and the uid
 * is the only thing a player can read off their own screen.
 */
class AdminEntitlementTest extends TestCase
{
    use AdminsPacks, RefreshDatabase;

    public function test_an_admin_grants_a_promo_claim_by_device_uid(): void
    {
        $player = Device::factory()->create(['device_uid' => 'tablet-uid-0001']);
        $pack = Pack::factory()->create(['slug' => 'meadow-mates']);

        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/entitlements', [
                'device_uid' => 'tablet-uid-0001',
                'pack_slug' => 'meadow-mates',
            ])
            ->assertCreated()
            ->assertJsonPath('source', Entitlement::SOURCE_PROMO)
            ->assertJsonPath('un_revoked', false);

        $entitlement = Entitlement::query()->sole();

        $this->assertSame($player->id, $entitlement->device_id);
        $this->assertSame($pack->id, $entitlement->pack_id);
        $this->assertNull($entitlement->revoked_at);
    }

    public function test_granting_twice_is_idempotent(): void
    {
        Device::factory()->create(['device_uid' => 'tablet-uid-0001']);
        Pack::factory()->create(['slug' => 'meadow-mates']);

        foreach (range(1, 2) as $ignored) {
            $this->withToken($this->adminToken())
                ->postJson('/api/v1/admin/entitlements', [
                    'device_uid' => 'tablet-uid-0001',
                    'pack_slug' => 'meadow-mates',
                ])
                ->assertCreated();
        }

        $this->assertSame(1, Entitlement::query()->count());
    }

    public function test_granting_a_revoked_claim_un_revokes_it(): void
    {
        $player = Device::factory()->create(['device_uid' => 'tablet-uid-0001']);
        $pack = Pack::factory()->create(['slug' => 'meadow-mates']);

        $entitlement = Entitlement::factory()->for($player)->for($pack)->create([
            'source' => Entitlement::SOURCE_PURCHASE,
            'revoked_at' => now()->subDay(),
        ]);

        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/entitlements', [
                'device_uid' => 'tablet-uid-0001',
                'pack_slug' => 'meadow-mates',
                'source' => Entitlement::SOURCE_GIFT,
            ])
            ->assertCreated()
            ->assertJsonPath('un_revoked', true)
            ->assertJsonPath('source', Entitlement::SOURCE_GIFT);

        $entitlement->refresh();

        // The same auditable row, brought back — not a second claim.
        $this->assertSame(1, Entitlement::query()->count());
        $this->assertNull($entitlement->revoked_at);
        $this->assertSame(Entitlement::SOURCE_GIFT, $entitlement->source);
    }

    public function test_an_unknown_device_is_a_404_rather_than_a_field_error(): void
    {
        Pack::factory()->create(['slug' => 'meadow-mates']);

        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/entitlements', [
                'device_uid' => 'nobody-at-all',
                'pack_slug' => 'meadow-mates',
            ])
            ->assertNotFound()
            ->assertJsonPath('error.code', 'DEVICE_NOT_FOUND');
    }

    public function test_an_unknown_pack_is_a_404(): void
    {
        Device::factory()->create(['device_uid' => 'tablet-uid-0001']);

        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/entitlements', [
                'device_uid' => 'tablet-uid-0001',
                'pack_slug' => 'nobody-home',
            ])
            ->assertNotFound()
            ->assertJsonPath('error.code', 'PACK_NOT_FOUND');
    }

    public function test_a_source_the_admin_may_not_forge_is_rejected(): void
    {
        Device::factory()->create(['device_uid' => 'tablet-uid-0001']);
        Pack::factory()->create(['slug' => 'meadow-mates']);

        // A purchase is written by the store verification path, and a free
        // claim writes itself on first download. Neither is a form field.
        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/entitlements', [
                'device_uid' => 'tablet-uid-0001',
                'pack_slug' => 'meadow-mates',
                'source' => Entitlement::SOURCE_PURCHASE,
            ])
            ->assertStatus(422);
    }

    public function test_a_non_admin_cannot_grant_anything(): void
    {
        $user = User::factory()->create();
        Device::factory()->create(['device_uid' => 'tablet-uid-0001']);
        Pack::factory()->create(['slug' => 'meadow-mates']);

        $this->withToken($this->adminToken($user))
            ->postJson('/api/v1/admin/entitlements', [
                'device_uid' => 'tablet-uid-0001',
                'pack_slug' => 'meadow-mates',
            ])
            ->assertForbidden();

        $this->assertSame(0, Entitlement::query()->count());
    }
}
