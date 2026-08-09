<?php

namespace Tests\Feature\Api;

use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\User;
use App\Services\Stores\FakeStoreReceiptVerifier;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * `POST /api/v1/entitlements/verify` — receipts are the restore path (BL-52,
 * DLC_SERVER.md §9, §4.3).
 *
 * The fake verifier makes this deterministic: a purchase token is valid iff it
 * begins `test-`. Everything below is therefore about the *seam* and the
 * ownership rules, not about Google's API — which is the point of having a seam
 * at all.
 */
class ReceiptVerificationTest extends TestCase
{
    use PublishesPacks, RefreshDatabase;

    /**
     * Wire the fake in for one platform. Nothing does this by default: every
     * platform ships unconfigured, so a deployment that forgot cannot silently
     * accept receipts it has no way of checking.
     */
    private function fakeStore(string $platform = 'google'): void
    {
        config(['coloringbook.stores.verifiers.'.$platform => FakeStoreReceiptVerifier::class]);
    }

    private function sellablePack(string $sku = 'coloringbook.forest_friends'): Pack
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;
        $pack->forceFill(['sku_google' => $sku])->save();

        return $pack;
    }

    public function test_a_valid_receipt_grants_the_pack_to_an_account(): void
    {
        $this->fakeStore();
        $pack = $this->sellablePack();

        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->postJson('/api/v1/entitlements/verify', [
                'platform' => 'google',
                'purchase_token' => 'test-purchase-abc',
                'sku' => 'coloringbook.forest_friends',
            ])
            ->assertOk()
            ->assertJsonPath('pack_slug', 'forest-friends')
            ->assertJsonPath('source', 'purchase')
            ->assertJsonPath('latest_version', 1);

        $this->assertDatabaseHas('entitlements', [
            'user_id' => $user->id,
            'device_id' => null,
            'pack_id' => $pack->id,
            'source' => Entitlement::SOURCE_PURCHASE,
            'platform' => 'google',
            'platform_txn_id' => 'test-purchase-abc',
            'revoked_at' => null,
        ]);
    }

    public function test_a_valid_receipt_grants_the_pack_to_an_anonymous_device(): void
    {
        $this->fakeStore();
        $pack = $this->sellablePack();

        $issued = $this->registerAnonymousDevice('tablet-uid');

        $this->withToken($issued->plainTextToken)
            ->postJson('/api/v1/entitlements/verify', [
                'platform' => 'google',
                'purchase_token' => 'test-purchase-abc',
                'sku' => 'coloringbook.forest_friends',
            ])
            ->assertOk()
            ->assertJsonPath('pack_slug', 'forest-friends');

        $this->assertDatabaseHas('entitlements', [
            'user_id' => null,
            'device_id' => $issued->device->id,
            'pack_id' => $pack->id,
            'source' => Entitlement::SOURCE_PURCHASE,
        ]);

        // …and the pack is now downloadable by a tablet nobody signed in on.
        $this->forgetResolvedGuards();

        $this->withToken($issued->plainTextToken)
            ->get('/api/v1/packs/forest-friends/download')
            ->assertRedirect();
    }

    /**
     * The requirement, as one assertion: *"allow the user to not need to
     * purchase coloring books twice between devices"*. The store hands the same
     * purchase token to both tablets; each earns its own row.
     */
    public function test_the_same_purchase_grants_on_every_device_that_presents_it(): void
    {
        $this->fakeStore();
        $this->sellablePack();

        $body = [
            'platform' => 'google',
            'purchase_token' => 'test-one-purchase',
            'sku' => 'coloringbook.forest_friends',
        ];

        foreach (['tablet-one-uid', 'tablet-two-uid'] as $uid) {
            $issued = $this->registerAnonymousDevice($uid);

            $this->forgetResolvedGuards();

            $this->withToken($issued->plainTextToken)
                ->postJson('/api/v1/entitlements/verify', $body)
                ->assertOk();
        }

        // Two rows, one purchase — which is why `platform_txn_id` uniqueness is
        // per owner rather than global.
        $this->assertSame(2, Entitlement::query()->where('platform_txn_id', 'test-one-purchase')->count());
    }

    public function test_verifying_twice_is_one_row(): void
    {
        $this->fakeStore();
        $this->sellablePack();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $body = [
            'platform' => 'google',
            'purchase_token' => 'test-purchase-abc',
            'sku' => 'coloringbook.forest_friends',
        ];

        $first = $this->withToken($bearer)->postJson('/api/v1/entitlements/verify', $body)->assertOk();
        $second = $this->withToken($bearer)->postJson('/api/v1/entitlements/verify', $body)->assertOk();

        $this->assertSame(1, Entitlement::query()->count());
        $this->assertSame($first->json('granted_at'), $second->json('granted_at'));
    }

    public function test_a_revoked_claim_stays_revoked(): void
    {
        $this->fakeStore();
        $pack = $this->sellablePack();

        $user = User::factory()->create();
        Entitlement::factory()->for($user)->for($pack)
            ->source(Entitlement::SOURCE_PURCHASE)
            ->revoked()
            ->create();

        $this->withToken($this->issueDeviceToken($user))
            ->postJson('/api/v1/entitlements/verify', [
                'platform' => 'google',
                'purchase_token' => 'test-purchase-abc',
                'sku' => 'coloringbook.forest_friends',
            ])
            ->assertForbidden()
            ->assertJsonPath('error.code', 'ENTITLEMENT_REQUIRED');

        // A receipt is not a way back. Un-revoking is an admin act (WP5), and
        // re-presenting a purchase token must never be one.
        $this->assertSame(1, Entitlement::query()->count());
        $this->assertNotNull(Entitlement::query()->sole()->revoked_at);
    }

    public function test_a_receipt_the_store_rejects_is_a_422_and_writes_nothing(): void
    {
        $this->fakeStore();
        $this->sellablePack();

        $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->postJson('/api/v1/entitlements/verify', [
                'platform' => 'google',
                'purchase_token' => 'not-a-real-purchase',
                'sku' => 'coloringbook.forest_friends',
            ])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'RECEIPT_INVALID');

        $this->assertSame(0, Entitlement::query()->count());
    }

    public function test_an_unconfigured_platform_answers_store_unavailable(): void
    {
        // No fakeStore() call: this is the shipped default, and it is the
        // safe one — a deployment with no store credentials refuses in a way
        // the client retries rather than accepting everything.
        $this->sellablePack();

        $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->postJson('/api/v1/entitlements/verify', [
                'platform' => 'google',
                'purchase_token' => 'test-purchase-abc',
                'sku' => 'coloringbook.forest_friends',
            ])
            ->assertStatus(503)
            ->assertJsonPath('error.code', 'STORE_UNAVAILABLE');

        $this->assertSame(0, Entitlement::query()->count());
    }

    public function test_the_fake_verifier_is_refused_in_production_however_it_is_configured(): void
    {
        $this->fakeStore();
        $this->sellablePack();

        app()->detectEnvironment(fn (): string => 'production');

        $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->postJson('/api/v1/entitlements/verify', [
                'platform' => 'google',
                'purchase_token' => 'test-purchase-abc',
                'sku' => 'coloringbook.forest_friends',
            ])
            ->assertStatus(503)
            ->assertJsonPath('error.code', 'STORE_UNAVAILABLE');

        $this->assertSame(0, Entitlement::query()->count());
    }

    public function test_a_sku_nobody_sells_is_a_404_and_the_store_is_never_asked(): void
    {
        $this->fakeStore();
        $this->sellablePack();

        $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->postJson('/api/v1/entitlements/verify', [
                'platform' => 'google',
                'purchase_token' => 'test-purchase-abc',
                'sku' => 'coloringbook.nothing_like_this',
            ])
            ->assertNotFound()
            ->assertJsonPath('error.code', 'NOT_FOUND');

        $this->assertSame(0, Entitlement::query()->count());
    }

    public function test_a_sku_is_read_on_the_platforms_own_column(): void
    {
        $this->fakeStore('apple');
        $this->sellablePack();

        // The pack's `sku_google` is set; asking Apple for the same string must
        // not find it, or one store's product ids would sell another's packs.
        $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->postJson('/api/v1/entitlements/verify', [
                'platform' => 'apple',
                'purchase_token' => 'test-purchase-abc',
                'sku' => 'coloringbook.forest_friends',
            ])
            ->assertNotFound();
    }

    public function test_a_platform_this_build_has_never_heard_of_is_a_422(): void
    {
        $this->sellablePack();

        // Deliberately not the 503: "we cannot ask that store" and "there is no
        // such store" are different problems with different remedies.
        $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->postJson('/api/v1/entitlements/verify', [
                'platform' => 'nintendo',
                'purchase_token' => 'test-purchase-abc',
                'sku' => 'coloringbook.forest_friends',
            ])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED');
    }

    public function test_it_needs_a_token_and_the_entitlements_read_ability(): void
    {
        $this->fakeStore();
        $this->sellablePack();

        $body = [
            'platform' => 'google',
            'purchase_token' => 'test-purchase-abc',
            'sku' => 'coloringbook.forest_friends',
        ];

        $this->postJson('/api/v1/entitlements/verify', $body)
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'UNAUTHENTICATED');

        $this->withToken($this->issueDeviceToken(User::factory()->create(), 'tablet', ['save:sync']))
            ->postJson('/api/v1/entitlements/verify', $body)
            ->assertForbidden()
            ->assertJsonPath('error.code', 'MISSING_ABILITY');
    }

    public function test_a_retired_pack_can_still_be_restored(): void
    {
        $this->fakeStore();
        $pack = $this->sellablePack();
        $pack->update(['status' => Pack::STATUS_RETIRED]);

        // Delisting must never take a bought pack away from the household that
        // bought it (§7.3), and a fresh install restoring from receipts is
        // exactly that household.
        $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->postJson('/api/v1/entitlements/verify', [
                'platform' => 'google',
                'purchase_token' => 'test-purchase-abc',
                'sku' => 'coloringbook.forest_friends',
            ])
            ->assertOk()
            ->assertJsonPath('pack_slug', 'forest-friends');
    }
}
