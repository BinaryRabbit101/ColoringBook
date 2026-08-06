<?php

namespace Tests\Feature\Api;

use App\Models\Device;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Route;
use Laravel\Sanctum\PersonalAccessToken;
use Tests\TestCase;

/**
 * The device-token lifecycle: issue, slide, revoke (DLC_SERVER.md §4.2).
 */
class TokenTest extends TestCase
{
    use RefreshDatabase;

    private function credentials(array $overrides = []): array
    {
        return [
            'email' => 'parent@example.com',
            'password' => 'a-good-password',
            'device_uid' => 'device-uid-tablet-01',
            'device_name' => "Ivy's tablet",
            'platform' => 'android',
            ...$overrides,
        ];
    }

    private function parent(): User
    {
        return User::factory()->create([
            'email' => 'parent@example.com',
            'password' => 'a-good-password',
        ]);
    }

    public function test_signing_in_returns_a_token_with_exactly_the_game_abilities(): void
    {
        $user = $this->parent();

        $response = $this->postJson('/api/v1/auth/token', $this->credentials());

        $response->assertOk()
            ->assertJsonStructure(['token', 'abilities', 'expires_at', 'user' => ['ulid', 'email']])
            ->assertJsonPath('user.ulid', $user->ulid)
            ->assertJsonPath('abilities', ['save:sync', 'entitlements:read', 'packs:download']);

        $token = PersonalAccessToken::findToken($response->json('token'));

        $this->assertNotNull($token);
        $this->assertSame('device-uid-tablet-01', $token->name);
        $this->assertSame(['save:sync', 'entitlements:read', 'packs:download'], $token->abilities);
    }

    public function test_the_token_expires_ninety_days_out(): void
    {
        $this->parent();

        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $response = $this->postJson('/api/v1/auth/token', $this->credentials());

        $expected = CarbonImmutable::now()->addDays(90);

        $this->assertSame(
            $expected->toIso8601String(),
            CarbonImmutable::parse($response->json('expires_at'))->toIso8601String(),
        );
    }

    public function test_signing_in_records_the_device(): void
    {
        $user = $this->parent();

        $this->postJson('/api/v1/auth/token', $this->credentials())->assertOk();

        $device = Device::query()->where('user_id', $user->id)->sole();

        $this->assertSame('device-uid-tablet-01', $device->device_uid);
        $this->assertSame("Ivy's tablet", $device->device_name);
        $this->assertSame('android', $device->platform);
        $this->assertNotNull($device->last_seen_at);
        $this->assertNotNull($device->ulid);
    }

    public function test_signing_in_again_on_the_same_device_replaces_that_devices_token(): void
    {
        $user = $this->parent();

        $first = $this->postJson('/api/v1/auth/token', $this->credentials())->json('token');
        $second = $this->postJson('/api/v1/auth/token', $this->credentials([
            'device_name' => 'The good tablet',
        ]))->json('token');

        $this->assertNotSame($first, $second);
        $this->assertSame(1, $user->tokens()->where('name', 'device-uid-tablet-01')->count());
        $this->assertSame(1, Device::query()->where('user_id', $user->id)->count());

        // The old bearer is dead; the new one works.
        $this->forgetResolvedGuards()->withToken($first)->getJson('/api/v1/me')->assertUnauthorized();
        $this->forgetResolvedGuards()->withToken($second)->getJson('/api/v1/me')->assertOk();

        // A name the client sent this time overwrites the old one.
        $this->assertSame('The good tablet', Device::query()->sole()->device_name);
    }

    public function test_other_devices_keep_their_tokens(): void
    {
        $this->parent();

        $tablet = $this->postJson('/api/v1/auth/token', $this->credentials())->json('token');
        $this->postJson('/api/v1/auth/token', $this->credentials([
            'device_uid' => 'device-uid-laptop-02',
            'device_name' => 'Kitchen laptop',
        ]))->assertOk();

        $this->withToken($tablet)->getJson('/api/v1/me')->assertOk();
        $this->assertDatabaseCount('devices', 2);
    }

    public function test_bad_credentials_are_rejected_with_a_stable_code(): void
    {
        $this->parent();

        $this->postJson('/api/v1/auth/token', $this->credentials(['password' => 'wrong']))
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'INVALID_CREDENTIALS');

        $this->assertDatabaseCount('personal_access_tokens', 0);
        $this->assertDatabaseCount('devices', 0);
    }

    public function test_an_unknown_email_looks_exactly_like_a_wrong_password(): void
    {
        $this->postJson('/api/v1/auth/token', $this->credentials(['email' => 'nobody@example.com']))
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'INVALID_CREDENTIALS');
    }

    public function test_the_device_uid_is_required(): void
    {
        $this->parent();

        $this->postJson('/api/v1/auth/token', $this->credentials(['device_uid' => '']))
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED');
    }

    public function test_refresh_slides_the_expiry_and_touches_the_device(): void
    {
        $user = $this->parent();

        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $token = $this->postJson('/api/v1/auth/token', $this->credentials())->json('token');

        $this->travelTo(CarbonImmutable::parse('2026-09-06 12:00:00'));

        $response = $this->withToken($token)->postJson('/api/v1/auth/refresh');

        $response->assertOk()->assertJsonStructure(['expires_at']);

        $this->assertSame(
            CarbonImmutable::now()->addDays(90)->toIso8601String(),
            CarbonImmutable::parse($response->json('expires_at'))->toIso8601String(),
        );

        $device = Device::query()->where('user_id', $user->id)->sole();

        $this->assertTrue($device->last_seen_at->equalTo(CarbonImmutable::now()));
    }

    public function test_refresh_requires_a_token(): void
    {
        $this->postJson('/api/v1/auth/refresh')
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'UNAUTHENTICATED');
    }

    public function test_deleting_the_token_signs_this_device_out_only(): void
    {
        $user = $this->parent();

        $tablet = $this->postJson('/api/v1/auth/token', $this->credentials())->json('token');
        $laptop = $this->postJson('/api/v1/auth/token', $this->credentials([
            'device_uid' => 'device-uid-laptop-02',
        ]))->json('token');

        $this->withToken($tablet)->deleteJson('/api/v1/auth/token')->assertNoContent();

        $this->forgetResolvedGuards()->withToken($tablet)->getJson('/api/v1/me')->assertUnauthorized();
        $this->forgetResolvedGuards()->withToken($laptop)->getJson('/api/v1/me')->assertOk();

        // The device row survives a sign-out; it is the record the install exists.
        $this->assertDatabaseCount('devices', 2);
        $this->assertSame(1, $user->tokens()->count());
    }

    public function test_an_expired_token_no_longer_authenticates(): void
    {
        $this->parent();

        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $token = $this->postJson('/api/v1/auth/token', $this->credentials())->json('token');

        $this->travelTo(CarbonImmutable::parse('2026-11-06 12:00:00'));

        $this->withToken($token)->getJson('/api/v1/me')
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'UNAUTHENTICATED');
    }

    public function test_auth_routes_carry_the_tighter_throttle(): void
    {
        $middleware = Route::getRoutes()->getByName('api.v1.auth.token.store')?->gatherMiddleware() ?? [];

        $this->assertContains('throttle:6,1', $middleware);
        $this->assertContains('throttle:60,1', $middleware);

        $refresh = Route::getRoutes()->getByName('api.v1.auth.refresh')?->gatherMiddleware() ?? [];

        $this->assertContains('throttle:60,1', $refresh);
        $this->assertContains('auth:sanctum', $refresh);
    }

    public function test_repeated_sign_in_attempts_are_throttled(): void
    {
        $this->parent();

        for ($i = 0; $i < 6; $i++) {
            $this->postJson('/api/v1/auth/token', $this->credentials(['password' => 'wrong']));
        }

        $this->postJson('/api/v1/auth/token', $this->credentials())
            ->assertStatus(429)
            ->assertJsonPath('error.code', 'THROTTLED');
    }
}
