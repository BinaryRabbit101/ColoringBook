<?php

namespace Tests\Feature\Api;

use App\Models\Device;
use App\Models\Entitlement;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Database\QueryException;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Sanctum\PersonalAccessToken;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * `POST /api/v1/device/register` — the anonymous tier (BL-52,
 * DLC_SERVER.md §4.3, §11).
 *
 * Two things are being proved here and they pull in opposite directions: an
 * anonymous device must be able to own and download packs, and it must never
 * be able to touch a child's artwork or somebody else's account.
 */
class DeviceRegistrationTest extends TestCase
{
    use PublishesPacks, RefreshDatabase;

    public function test_it_creates_an_anonymous_device_and_returns_a_token(): void
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

        $this->assertNull($device->user_id);
        $this->assertSame('tablet-in-the-kitchen', $device->device_uid);
        $this->assertSame('Kitchen tablet', $device->device_name);
        $this->assertSame('android', $device->platform);
        $this->assertSame($device->ulid, $response->json('device.ulid'));

        // The ULID crosses the boundary; the numeric key never does.
        $this->assertArrayNotHasKey('id', (array) $response->json('device'));
    }

    public function test_the_token_carries_exactly_two_abilities_and_never_save_sync(): void
    {
        $response = $this->postJson('/api/v1/device/register', [
            'device_uid' => 'tablet-in-the-kitchen',
        ])->assertOk();

        $this->assertSame(['entitlements:read', 'packs:download'], $response->json('abilities'));

        $token = PersonalAccessToken::query()->sole();

        $this->assertSame(['entitlements:read', 'packs:download'], $token->abilities);
        $this->assertSame(Device::class, $token->tokenable_type);
        $this->assertNotContains('save:sync', (array) $token->abilities);
    }

    public function test_the_token_gets_the_same_ninety_day_window_and_slides(): void
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

        // And `SlideTokenExpiry` keeps working for it: the window is the same
        // window, the tokenable is the only thing that differs.
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

    public function test_a_uid_that_belongs_to_an_account_is_never_exposed(): void
    {
        $user = User::factory()->create();
        $linked = Device::factory()->for($user)->create(['device_uid' => 'shared-uid']);

        $response = $this->postJson('/api/v1/device/register', ['device_uid' => 'shared-uid'])
            ->assertOk();

        $anonymous = Device::query()->anonymous()->sole();

        // A brand-new, empty identity — not the household's row.
        $this->assertNotSame($linked->ulid, $response->json('device.ulid'));
        $this->assertSame($anonymous->ulid, $response->json('device.ulid'));
        $this->assertDatabaseCount('devices', 2);

        // …and the account's device did not lose its account or its tokens.
        $linked->refresh();
        $this->assertSame($user->id, $linked->user_id);
    }

    public function test_an_anonymous_device_cannot_reach_anything_gated_on_save_sync(): void
    {
        $bearer = (string) $this->postJson('/api/v1/device/register', ['device_uid' => 'tablet-uid'])
            ->json('token');

        // The whole sync surface, plus the two account routes on the same gate.
        // This is the compliance claim of §4.3 as an assertion: an anonymous
        // device can own packs, it can never upload a child's artwork.
        $calls = [
            ['getJson', '/api/v1/sync/progress'],
            ['putJson', '/api/v1/sync/progress'],
            ['deleteJson', '/api/v1/sync/progress'],
            ['postJson', '/api/v1/sync/paint/coyote-2026/0'],
            ['getJson', '/api/v1/sync/paint/coyote-2026/0'],
            ['deleteJson', '/api/v1/sync/paint/coyote-2026/0'],
            ['getJson', '/api/v1/me'],
            ['getJson', '/api/v1/profiles'],
        ];

        foreach ($calls as [$verb, $url]) {
            $this->forgetResolvedGuards();

            $this->withToken($bearer)->{$verb}($url)
                ->assertForbidden()
                ->assertJsonPath('error.code', 'MISSING_ABILITY');
        }
    }

    public function test_an_anonymous_device_reads_its_own_entitlements_and_only_its_own(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        $issued = $this->registerAnonymousDevice('tablet-uid');
        $other = $this->registerAnonymousDevice('other-tablet-uid');

        Entitlement::factory()->ownedByDevice($issued->device)->for($pack)
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

    public function test_an_anonymous_device_downloads_the_paid_pack_it_owns(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        $issued = $this->registerAnonymousDevice('tablet-uid');

        $this->withToken($issued->plainTextToken)
            ->getJson('/api/v1/packs/forest-friends/download')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'ENTITLEMENT_REQUIRED');

        Entitlement::factory()->ownedByDevice($issued->device)->for($pack)
            ->source(Entitlement::SOURCE_PURCHASE)
            ->create();

        $this->forgetResolvedGuards();

        $this->withToken($issued->plainTextToken)
            ->get('/api/v1/packs/forest-friends/download')
            ->assertRedirect();

        // …and the shop says so, which is what turns "Buy" into "Download" on a
        // tablet nobody has signed in on.
        $this->forgetResolvedGuards();

        $this->withToken($issued->plainTextToken)
            ->getJson('/api/v1/packs')
            ->assertOk()
            ->assertJsonPath('packs.0.owned', true);
    }

    /**
     * The generated column earning its keep. `UNIQUE(user_id, device_uid)`
     * alone would allow this, because SQL treats two NULLs as distinct — which
     * is exactly the hole `owner_key = coalesce(user_id, 0)` closes.
     */
    public function test_the_database_refuses_a_second_anonymous_row_for_one_uid(): void
    {
        $this->registerAnonymousDevice('tablet-uid');

        $this->expectException(QueryException::class);

        Device::query()->create(['device_uid' => 'tablet-uid']);
    }

    public function test_per_account_uniqueness_of_a_uid_is_unchanged(): void
    {
        $user = User::factory()->create();
        Device::factory()->for($user)->create(['device_uid' => 'tablet-uid']);

        // Two accounts may each hold the same uid (a reinstall on a shared
        // tablet); one account may not hold it twice.
        Device::factory()->for(User::factory())->create(['device_uid' => 'tablet-uid']);
        $this->assertDatabaseCount('devices', 2);

        $this->expectException(QueryException::class);

        Device::factory()->for($user)->create(['device_uid' => 'tablet-uid']);
    }

    public function test_the_uid_is_validated_like_the_sign_in_route_validates_it(): void
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
}
