<?php

namespace Tests\Feature\Api;

use App\Models\Device;
use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Testing\TestResponse;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * Linking is adoption (BL-52, DLC_SERVER.md §4.3).
 *
 * A tablet buys two packs, a grown-up later makes an account and signs in on
 * that same tablet — and the packs are the household's. The anonymous identity
 * ends there: its tokens die and its row goes, so there is never a second
 * inventory sitting under an account that nobody can see.
 */
class DeviceAdoptionTest extends TestCase
{
    use PublishesPacks, RefreshDatabase;

    private function signIn(User $user, string $deviceUid): TestResponse
    {
        return $this->postJson('/api/v1/auth/token', [
            'email' => $user->email,
            'password' => 'password',
            'device_uid' => $deviceUid,
            'device_name' => 'The tablet',
        ]);
    }

    public function test_signing_in_moves_the_devices_packs_to_the_account(): void
    {
        $this->fakePackStorage();
        $forest = $this->publishFixturePack()->pack;
        $meadow = Pack::factory()->create(['slug' => 'meadow-mates', 'status' => Pack::STATUS_PUBLISHED]);

        $issued = $this->registerAnonymousDevice('tablet-uid');

        foreach ([$forest, $meadow] as $pack) {
            Entitlement::factory()->ownedByDevice($issued->device)->for($pack)
                ->source(Entitlement::SOURCE_PURCHASE)
                ->create(['platform' => 'google', 'platform_txn_id' => 'txn-'.$pack->slug]);
        }

        $user = User::factory()->create();

        $this->signIn($user, 'tablet-uid')->assertOk();

        // Both claims are the account's now — same rows, moved, so a purchase
        // stays auditable as the row it always was.
        $this->assertSame(2, Entitlement::query()->where('user_id', $user->id)->count());
        $this->assertSame(0, Entitlement::query()->whereNotNull('device_id')->count());
        $this->assertSame(2, Entitlement::query()->count());

        $this->assertDatabaseHas('entitlements', [
            'user_id' => $user->id,
            'device_id' => null,
            'pack_id' => $forest->id,
            'source' => Entitlement::SOURCE_PURCHASE,
            'platform_txn_id' => 'txn-forest-friends',
        ]);
    }

    public function test_the_anonymous_row_and_its_token_are_gone(): void
    {
        $issued = $this->registerAnonymousDevice('tablet-uid');
        $user = User::factory()->create();

        $accountToken = (string) $this->signIn($user, 'tablet-uid')->assertOk()->json('token');

        // The anonymous identity ends at sign-in. The *linked* row for the same
        // uid is created by the sign-in itself, so exactly one device survives.
        $this->assertSame(0, Device::query()->anonymous()->count());
        $this->assertDatabaseCount('devices', 1);
        $this->assertSame($user->id, Device::query()->sole()->user_id);

        // Sanctum's RequestGuard memoises whoever it resolved, so a revoked
        // token appears to keep working without this.
        $this->forgetResolvedGuards();
        $this->withToken($issued->plainTextToken)
            ->getJson('/api/v1/entitlements')
            ->assertUnauthorized();

        $this->forgetResolvedGuards();
        $this->withToken($accountToken)->getJson('/api/v1/entitlements')->assertOk();
    }

    public function test_it_is_a_union_and_the_accounts_own_row_always_wins(): void
    {
        $this->fakePackStorage();
        $shared = $this->publishFixturePack()->pack;
        $deviceOnly = Pack::factory()->create(['slug' => 'meadow-mates', 'status' => Pack::STATUS_PUBLISHED]);

        $issued = $this->registerAnonymousDevice('tablet-uid');
        $user = User::factory()->create();

        // The account already has the shared pack, as a promo…
        Entitlement::factory()->for($user)->for($shared)->source(Entitlement::SOURCE_PROMO)->create();
        // …and the device thinks it bought it, plus one the account has never
        // heard of.
        Entitlement::factory()->ownedByDevice($issued->device)->for($shared)
            ->source(Entitlement::SOURCE_PURCHASE)->create();
        Entitlement::factory()->ownedByDevice($issued->device)->for($deviceOnly)
            ->source(Entitlement::SOURCE_PURCHASE)->create();

        $this->signIn($user, 'tablet-uid')->assertOk();

        $this->assertSame(2, Entitlement::query()->count());

        // The account's row is untouched — one row per (owner, pack), and the
        // account's is the one that was already there.
        $this->assertDatabaseHas('entitlements', [
            'user_id' => $user->id,
            'pack_id' => $shared->id,
            'source' => Entitlement::SOURCE_PROMO,
        ]);
        $this->assertDatabaseHas('entitlements', [
            'user_id' => $user->id,
            'pack_id' => $deviceOnly->id,
            'source' => Entitlement::SOURCE_PURCHASE,
        ]);
    }

    /**
     * The case the union rule exists for. A refund or an admin take-back must
     * not be undone by signing in on a tablet that still remembers owning it.
     */
    public function test_a_pack_the_account_holds_revoked_stays_revoked(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        $issued = $this->registerAnonymousDevice('tablet-uid');
        $user = User::factory()->create();

        Entitlement::factory()->for($user)->for($pack)->revoked()->create();
        Entitlement::factory()->ownedByDevice($issued->device)->for($pack)
            ->source(Entitlement::SOURCE_PURCHASE)->create();

        $bearer = (string) $this->signIn($user, 'tablet-uid')->assertOk()->json('token');

        $this->assertSame(1, Entitlement::query()->count());
        $this->assertNotNull(Entitlement::query()->sole()->revoked_at);

        $this->forgetResolvedGuards();
        $this->withToken($bearer)->getJson('/api/v1/entitlements')
            ->assertOk()
            ->assertJsonCount(0);
    }

    public function test_adoption_is_idempotent(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        $issued = $this->registerAnonymousDevice('tablet-uid');
        Entitlement::factory()->ownedByDevice($issued->device)->for($pack)
            ->source(Entitlement::SOURCE_PURCHASE)->create();

        $user = User::factory()->create();

        $this->signIn($user, 'tablet-uid')->assertOk();
        $this->forgetResolvedGuards();
        $this->signIn($user, 'tablet-uid')->assertOk();
        $this->forgetResolvedGuards();
        $this->signIn($user, 'tablet-uid')->assertOk();

        $this->assertSame(1, Entitlement::query()->count());
        $this->assertDatabaseCount('devices', 1);
        $this->assertSame(1, Entitlement::query()->where('user_id', $user->id)->count());
    }

    public function test_signing_in_with_no_anonymous_row_changes_nothing(): void
    {
        $user = User::factory()->create();

        $this->signIn($user, 'a-uid-nobody-registered')->assertOk();

        $this->assertDatabaseCount('devices', 1);
        $this->assertSame(0, Entitlement::query()->count());
    }

    public function test_another_households_anonymous_device_is_not_adopted(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        $issued = $this->registerAnonymousDevice('other-tablet-uid');
        Entitlement::factory()->ownedByDevice($issued->device)->for($pack)
            ->source(Entitlement::SOURCE_PURCHASE)->create();

        $user = User::factory()->create();

        // Adoption keys on the uid the client presents, and only that one.
        $this->signIn($user, 'this-tablet-uid')->assertOk();

        $this->assertSame(1, Device::query()->anonymous()->count());
        $this->assertSame(0, Entitlement::query()->where('user_id', $user->id)->count());
        $this->assertSame(1, Entitlement::query()->where('device_id', $issued->device->id)->count());
    }
}
