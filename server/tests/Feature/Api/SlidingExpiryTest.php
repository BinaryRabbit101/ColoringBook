<?php

namespace Tests\Feature\Api;

use App\Models\Device;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Sanctum\PersonalAccessToken;
use Tests\TestCase;

/**
 * "Expiry: 90 days sliding; refresh on any successful call" — DLC_SERVER.md
 * §4.2, implemented as an after-middleware on the whole `api` group so every
 * work package gets it without doing anything.
 */
class SlidingExpiryTest extends TestCase
{
    use RefreshDatabase;

    private function tokenFor(Device $device): PersonalAccessToken
    {
        /** @var PersonalAccessToken $token */
        $token = $device->tokens()->firstOrFail();

        return $token;
    }

    public function test_a_successful_call_slides_the_expiry_forward(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $device = Device::factory()->create();
        $bearer = $this->issueDeviceToken($device);

        $this->travelTo(CarbonImmutable::parse('2026-08-09 12:00:00'));

        $this->withToken($bearer)->getJson('/api/v1/entitlements')->assertOk();

        $this->assertSame(
            CarbonImmutable::now()->addDays(90)->toIso8601String(),
            CarbonImmutable::createFromInterface($this->tokenFor($device)->expires_at)->toIso8601String(),
        );
    }

    public function test_a_fresh_token_is_left_alone(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $device = Device::factory()->create();
        $bearer = $this->issueDeviceToken($device);

        $before = $this->tokenFor($device)->expires_at;

        // Well inside the one-day slide threshold: no write.
        $this->travelTo(CarbonImmutable::parse('2026-08-06 20:00:00'));

        $this->withToken($bearer)->getJson('/api/v1/entitlements')->assertOk();

        $this->assertSame(
            CarbonImmutable::createFromInterface($before)->toIso8601String(),
            CarbonImmutable::createFromInterface($this->tokenFor($device)->expires_at)->toIso8601String(),
        );
    }

    public function test_the_slide_threshold_is_config_driven(): void
    {
        config(['coloringbook.token.slide_after_days' => 10]);

        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $device = Device::factory()->create();
        $bearer = $this->issueDeviceToken($device);

        $before = $this->tokenFor($device)->expires_at;

        $this->travelTo(CarbonImmutable::parse('2026-08-12 12:00:00'));
        $this->withToken($bearer)->getJson('/api/v1/entitlements')->assertOk();

        $this->assertSame(
            CarbonImmutable::createFromInterface($before)->toIso8601String(),
            CarbonImmutable::createFromInterface($this->tokenFor($device)->expires_at)->toIso8601String(),
        );

        $this->travelTo(CarbonImmutable::parse('2026-08-20 12:00:00'));
        $this->withToken($bearer)->getJson('/api/v1/entitlements')->assertOk();

        $this->assertSame(
            CarbonImmutable::now()->addDays(90)->toIso8601String(),
            CarbonImmutable::createFromInterface($this->tokenFor($device)->expires_at)->toIso8601String(),
        );
    }

    public function test_a_failed_call_slides_nothing(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $device = Device::factory()->create();

        // A token that authenticates but can't reach /entitlements.
        $bearer = $this->issueDeviceToken($device, abilities: ['packs:download']);

        $before = $this->tokenFor($device)->expires_at;

        $this->travelTo(CarbonImmutable::parse('2026-08-09 12:00:00'));

        $this->withToken($bearer)->getJson('/api/v1/entitlements')->assertForbidden();

        $this->assertSame(
            CarbonImmutable::createFromInterface($before)->toIso8601String(),
            CarbonImmutable::createFromInterface($this->tokenFor($device)->expires_at)->toIso8601String(),
        );
    }

    public function test_a_successful_call_marks_the_device_as_seen(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $device = Device::factory()->create();
        $bearer = $this->issueDeviceToken($device);

        Device::query()->update(['last_seen_at' => CarbonImmutable::parse('2026-08-01 12:00:00')]);

        $this->travelTo(CarbonImmutable::parse('2026-08-09 12:00:00'));

        $this->withToken($bearer)->getJson('/api/v1/entitlements')->assertOk();

        $this->assertTrue(
            Device::query()->sole()->last_seen_at->equalTo(CarbonImmutable::now()),
        );
    }

    public function test_a_recently_seen_device_is_not_written_again(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $device = Device::factory()->create();
        $bearer = $this->issueDeviceToken($device);

        $seenAt = CarbonImmutable::parse('2026-08-06 11:58:00');
        Device::query()->update(['last_seen_at' => $seenAt]);

        $this->withToken($bearer)->getJson('/api/v1/entitlements')->assertOk();

        $this->assertTrue(Device::query()->sole()->last_seen_at->equalTo($seenAt));
    }

    public function test_a_dashboard_session_has_no_token_to_slide(): void
    {
        // A session-backed request carries a TransientToken; the middleware
        // must simply step over it rather than exploding.
        $this->actingAs(User::factory()->create())->get(route('profile.edit'))->assertOk();

        $this->assertDatabaseCount('personal_access_tokens', 0);
    }
}
