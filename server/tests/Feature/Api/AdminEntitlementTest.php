<?php

namespace Tests\Feature\Api;

use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\AdminsPacks;
use Tests\TestCase;

/**
 * `POST /api/v1/admin/entitlements` — the promo grant, and the un-revoke that
 * WP3 deliberately left unbuilt (§9: "un-revoking is a deliberate admin act").
 */
class AdminEntitlementTest extends TestCase
{
    use AdminsPacks, RefreshDatabase;

    public function test_an_admin_grants_a_promo_claim_by_email(): void
    {
        $parent = User::factory()->create(['email' => 'parent@example.com']);
        $pack = Pack::factory()->create(['slug' => 'meadow-mates']);

        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/entitlements', [
                'email' => 'parent@example.com',
                'pack_slug' => 'meadow-mates',
            ])
            ->assertCreated()
            ->assertJsonPath('source', Entitlement::SOURCE_PROMO)
            ->assertJsonPath('un_revoked', false);

        $entitlement = Entitlement::query()->sole();

        $this->assertSame($parent->id, $entitlement->user_id);
        $this->assertSame($pack->id, $entitlement->pack_id);
        $this->assertNull($entitlement->revoked_at);
    }

    public function test_granting_twice_is_idempotent(): void
    {
        User::factory()->create(['email' => 'parent@example.com']);
        Pack::factory()->create(['slug' => 'meadow-mates']);

        foreach (range(1, 2) as $ignored) {
            $this->withToken($this->adminToken())
                ->postJson('/api/v1/admin/entitlements', [
                    'email' => 'parent@example.com',
                    'pack_slug' => 'meadow-mates',
                ])
                ->assertCreated();
        }

        $this->assertSame(1, Entitlement::query()->count());
    }

    public function test_granting_a_revoked_claim_un_revokes_it(): void
    {
        $parent = User::factory()->create(['email' => 'parent@example.com']);
        $pack = Pack::factory()->create(['slug' => 'meadow-mates']);

        $entitlement = Entitlement::factory()->for($parent)->for($pack)->create([
            'source' => Entitlement::SOURCE_PURCHASE,
            'revoked_at' => now()->subDay(),
        ]);

        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/entitlements', [
                'email' => 'parent@example.com',
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

    public function test_an_unknown_email_is_a_404_rather_than_a_field_error(): void
    {
        Pack::factory()->create(['slug' => 'meadow-mates']);

        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/entitlements', [
                'email' => 'nobody@example.com',
                'pack_slug' => 'meadow-mates',
            ])
            ->assertNotFound()
            ->assertJsonPath('error.code', 'USER_NOT_FOUND');
    }

    public function test_an_unknown_pack_is_a_404(): void
    {
        User::factory()->create(['email' => 'parent@example.com']);

        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/entitlements', [
                'email' => 'parent@example.com',
                'pack_slug' => 'nobody-home',
            ])
            ->assertNotFound()
            ->assertJsonPath('error.code', 'PACK_NOT_FOUND');
    }

    public function test_a_source_the_admin_may_not_forge_is_rejected(): void
    {
        User::factory()->create(['email' => 'parent@example.com']);
        Pack::factory()->create(['slug' => 'meadow-mates']);

        // A purchase is written by the store verification path, and a free
        // claim writes itself on first download. Neither is a form field.
        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/entitlements', [
                'email' => 'parent@example.com',
                'pack_slug' => 'meadow-mates',
                'source' => Entitlement::SOURCE_PURCHASE,
            ])
            ->assertStatus(422);
    }

    public function test_a_non_admin_cannot_grant_anything(): void
    {
        $user = User::factory()->create();
        User::factory()->create(['email' => 'parent@example.com']);
        Pack::factory()->create(['slug' => 'meadow-mates']);

        $this->withToken($this->adminToken($user))
            ->postJson('/api/v1/admin/entitlements', [
                'email' => 'parent@example.com',
                'pack_slug' => 'meadow-mates',
            ])
            ->assertForbidden();

        $this->assertSame(0, Entitlement::query()->count());
    }
}
