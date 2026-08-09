<?php

namespace Tests\Feature\Api;

use App\Models\Device;
use App\Models\Entitlement;
use Carbon\CarbonImmutable;
use Illuminate\Database\QueryException;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Route;
use Laravel\Sanctum\PersonalAccessToken;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * `POST /api/v1/device/register` — **the only client identity**
 * (DLC_SERVER.md §4.3, §11).
 *
 * The contract this file pins, because the game client codes against it:
 *
 *     {device_uid, device_name, platform}
 *       → {token, abilities, expires_at, device: {ulid}}
 *
 * find-or-create, `throttle:6,1`, abilities exactly
 * `entitlements:read` + `packs:download`.
 */
class DeviceRegistrationTest extends TestCase
{
    use PublishesPacks, RefreshDatabase;

    public function test_it_creates_a_device_and_returns_a_token(): void
    {
        $response = $this->postJson('/api/v1/device/register', [
            'device_uid' => 'tablet-in-the-kitchen',
            'device_name' => 'Kitchen tablet',
            'platform' => 'android',
        ])->assertOk();

        $this->assertSame(
            ['token', 'abilities', 'expires_at', 'device'],
            array_keys((array) $response->json()),
        );

        $device = Device::query()->sole();

        $this->assertSame('tablet-in-the-kitchen', $device->device_uid);
        $this->assertSame('Kitchen tablet', $device->device_name);
        $this->assertSame('android', $device->platform);
        $this->assertSame($device->ulid, $response->json('device.ulid'));

        // The ULID crosses the boundary; the numeric key never does.
        $this->assertArrayNotHasKey('id', (array) $response->json('device'));
    }

    public function test_the_token_carries_exactly_the_two_abilities(): void
    {
        $response = $this->postJson('/api/v1/device/register', [
            'device_uid' => 'tablet-in-the-kitchen',
        ])->assertOk();

        $this->assertSame(['entitlements:read', 'packs:download'], $response->json('abilities'));

        $token = PersonalAccessToken::query()->sole();

        $this->assertSame(['entitlements:read', 'packs:download'], $token->abilities);
        $this->assertSame(Device::class, $token->tokenable_type);
        $this->assertNotContains('admin', (array) $token->abilities);
    }

    public function test_the_token_gets_a_ninety_day_window_and_slides(): void
    {
        $expiresAt = CarbonImmutable::parse(
            (string) $this->postJson('/api/v1/device/register', ['device_uid' => 'tablet-uid'])
                ->json('expires_at'),
        );

        $this->assertEqualsWithDelta(
            (int) config('coloringbook.token.ttl_days'),
            CarbonImmutable::now()->diffInDays($expiresAt),
            1,
        );

        $bearer = (string) $this->postJson('/api/v1/device/register', ['device_uid' => 'tablet-uid'])
            ->json('token');

        $this->travel(30)->days();

        $this->withToken($bearer)->getJson('/api/v1/entitlements')->assertOk();

        $slid = PersonalAccessToken::query()->sole();
        $this->assertNotNull($slid->expires_at);
        $this->assertTrue(
            CarbonImmutable::createFromInterface($slid->expires_at)
                ->greaterThan(CarbonImmutable::now()->addDays(80)),
        );
    }

    /**
     * The whole reason there is no refresh route: registering again with the
     * uid the client has held since install is a *fresh token on the same
     * identity*, so a 401 is recovered by one idempotent call.
     */
    public function test_registering_again_rotates_the_token_and_keeps_the_row(): void
    {
        $first = (string) $this->postJson('/api/v1/device/register', ['device_uid' => 'tablet-uid'])
            ->json('token');

        $device = Device::query()->sole();

        $second = (string) $this->postJson('/api/v1/device/register', ['device_uid' => 'tablet-uid'])
            ->json('token');

        $this->assertNotSame($first, $second);
        $this->assertDatabaseCount('devices', 1);
        $this->assertSame($device->id, Device::query()->sole()->id);
        $this->assertSame(1, PersonalAccessToken::query()->count());

        // The old credential is dead. Without forgetting the guards, Sanctum's
        // memoised RequestGuard would happily keep answering with it.
        $this->forgetResolvedGuards();
        $this->withToken($first)->getJson('/api/v1/entitlements')->assertUnauthorized();

        $this->forgetResolvedGuards();
        $this->withToken($second)->getJson('/api/v1/entitlements')->assertOk();
    }

    /**
     * Re-auth must not cost a player their books. This is the assertion behind
     * "there is no refresh route".
     */
    public function test_re_registering_keeps_the_entitlements(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        $issued = $this->registerDevice('tablet-uid');

        Entitlement::factory()->for($issued->device)->for($pack)
            ->source(Entitlement::SOURCE_PURCHASE)
            ->create();

        $bearer = (string) $this->postJson('/api/v1/device/register', ['device_uid' => 'tablet-uid'])
            ->json('token');

        $this->forgetResolvedGuards();

        $this->withToken($bearer)
            ->getJson('/api/v1/entitlements')
            ->assertOk()
            ->assertJsonCount(1)
            ->assertJsonPath('0.pack_slug', 'forest-friends');
    }

    public function test_a_device_reads_its_own_entitlements_and_only_its_own(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        $issued = $this->registerDevice('tablet-uid');
        $other = $this->registerDevice('other-tablet-uid');

        Entitlement::factory()->for($issued->device)->for($pack)
            ->source(Entitlement::SOURCE_PURCHASE)
            ->create();

        $this->withToken($issued->plainTextToken)
            ->getJson('/api/v1/entitlements')
            ->assertOk()
            ->assertJsonCount(1)
            ->assertJsonPath('0.pack_slug', 'forest-friends')
            ->assertJsonPath('0.latest_version', 1)
            ->assertJsonPath('0.source', 'purchase');

        $this->forgetResolvedGuards();

        $this->withToken($other->plainTextToken)
            ->getJson('/api/v1/entitlements')
            ->assertOk()
            ->assertJsonCount(0);
    }

    public function test_a_device_downloads_the_paid_pack_it_owns(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        $issued = $this->registerDevice('tablet-uid');

        $this->withToken($issued->plainTextToken)
            ->getJson('/api/v1/packs/forest-friends/download')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'ENTITLEMENT_REQUIRED');

        Entitlement::factory()->for($issued->device)->for($pack)
            ->source(Entitlement::SOURCE_PURCHASE)
            ->create();

        $this->forgetResolvedGuards();

        $this->withToken($issued->plainTextToken)
            ->get('/api/v1/packs/forest-friends/download')
            ->assertRedirect();

        // …and the shop says so, which is what turns "Buy" into "Download".
        $this->forgetResolvedGuards();

        $this->withToken($issued->plainTextToken)
            ->getJson('/api/v1/packs')
            ->assertOk()
            ->assertJsonPath('packs.0.owned', true);
    }

    /**
     * `device_uid` is globally unique now that nothing scopes it. Two rows for
     * one uid would be two inventories for one install, and the second one
     * would silently be the empty one.
     */
    public function test_the_database_refuses_a_second_row_for_one_uid(): void
    {
        $this->registerDevice('tablet-uid');

        $this->expectException(QueryException::class);

        Device::query()->create(['device_uid' => 'tablet-uid']);
    }

    public function test_the_uid_is_bounded(): void
    {
        $this->postJson('/api/v1/device/register', [])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED')
            ->assertJsonPath('error.details.device_uid.0', 'The device uid field is required.');

        $this->postJson('/api/v1/device/register', ['device_uid' => 'short'])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED');

        $this->assertDatabaseCount('devices', 0);
    }

    /**
     * The pinned rate limit. Asserted on the route rather than by hammering it:
     * the two unnamed limiters (`throttle:60,1` from the group and this one)
     * share a cache key, so a request costs each of them a hit and counting
     * responses would pin that quirk instead of the contract.
     */
    public function test_registration_carries_the_tighter_rate_limit(): void
    {
        $route = Route::getRoutes()->getByName('api.v1.device.register');

        $this->assertNotNull($route);
        $this->assertContains('throttle:6,1', $route->gatherMiddleware());
        $this->assertContains('throttle:60,1', $route->gatherMiddleware());
    }

    public function test_hammering_registration_is_throttled_in_the_house_shape(): void
    {
        for ($i = 0; $i < 12; $i++) {
            $response = $this->postJson('/api/v1/device/register', ['device_uid' => 'tablet-uid-'.$i]);

            if ($response->getStatusCode() === 429) {
                $response->assertJsonPath('error.code', 'THROTTLED')
                    ->assertHeader('Retry-After');

                return;
            }
        }

        $this->fail('Registration was never throttled.');
    }
}
