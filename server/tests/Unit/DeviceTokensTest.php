<?php

namespace Tests\Unit;

use App\Models\Device;
use App\Services\DeviceTokens;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Sanctum\PersonalAccessToken;
use Tests\TestCase;

/**
 * The sliding-window arithmetic on its own, without an HTTP request in the
 * way (DLC_SERVER.md §4.2).
 */
class DeviceTokensTest extends TestCase
{
    use RefreshDatabase;

    private function tokens(): DeviceTokens
    {
        return app(DeviceTokens::class);
    }

    private function tokenExpiring(CarbonImmutable $at): PersonalAccessToken
    {
        $device = Device::factory()->create(['device_uid' => 'device-uid']);

        $device->createToken('device-uid', $this->tokens()->abilities(), $at);

        /** @var PersonalAccessToken $token */
        $token = $device->tokens()->firstOrFail();

        return $token;
    }

    public function test_the_abilities_are_exactly_the_two_the_game_needs(): void
    {
        $this->assertSame(
            ['entitlements:read', 'packs:download'],
            $this->tokens()->abilities(),
        );
    }

    public function test_a_new_expiry_is_a_full_window_from_now(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $this->assertTrue(
            $this->tokens()->expiresAt()->equalTo(CarbonImmutable::parse('2026-11-04 12:00:00')),
        );
    }

    public function test_the_window_length_is_config_driven(): void
    {
        config(['coloringbook.token.ttl_days' => 7]);

        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $this->assertTrue(
            $this->tokens()->expiresAt()->equalTo(CarbonImmutable::parse('2026-08-13 12:00:00')),
        );
    }

    public function test_a_token_inside_the_threshold_does_not_slide(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $token = $this->tokenExpiring(CarbonImmutable::now()->addDays(90));

        $this->travelTo(CarbonImmutable::parse('2026-08-07 11:00:00'));

        $this->assertFalse($this->tokens()->shouldSlide($token));
    }

    public function test_a_token_past_the_threshold_slides(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $token = $this->tokenExpiring(CarbonImmutable::now()->addDays(90));

        $this->travelTo(CarbonImmutable::parse('2026-08-07 13:00:00'));

        $this->assertTrue($this->tokens()->shouldSlide($token));

        $expiresAt = $this->tokens()->slide($token);

        $this->assertTrue($expiresAt->equalTo(CarbonImmutable::now()->addDays(90)));
        $this->assertTrue(
            CarbonImmutable::createFromInterface($token->fresh()->expires_at)
                ->equalTo(CarbonImmutable::now()->addDays(90)),
        );
    }

    public function test_a_token_without_an_expiry_is_left_alone(): void
    {
        $device = Device::factory()->create();
        $device->createToken('device-uid', $this->tokens()->abilities());

        /** @var PersonalAccessToken $token */
        $token = $device->tokens()->firstOrFail();

        $this->assertFalse($this->tokens()->shouldSlide($token));
    }

    public function test_a_device_is_only_touched_once_it_is_stale(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $seenAt = CarbonImmutable::parse('2026-08-06 11:55:00');
        $device = Device::factory()->create(['last_seen_at' => $seenAt]);

        $this->tokens()->touchDevice($device);
        $this->assertTrue($device->fresh()->last_seen_at->equalTo($seenAt));

        // Forced, e.g. by a fresh registration.
        $this->tokens()->touchDevice($device, force: true);
        $this->assertTrue($device->fresh()->last_seen_at->equalTo(CarbonImmutable::now()));
    }

    public function test_a_device_that_has_never_been_seen_is_touched(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $device = Device::factory()->neverSeen()->create();

        $this->tokens()->touchDevice($device);

        $this->assertTrue($device->fresh()->last_seen_at->equalTo(CarbonImmutable::now()));
    }

    /**
     * A device token is minted on the device row, so the tokenable *is* the
     * identity — there is nothing to look up. An admin token hangs off a
     * `User` and has no device at all.
     */
    public function test_the_device_behind_an_identity_is_the_tokenable_itself(): void
    {
        $device = Device::factory()->create(['device_uid' => 'device-uid-tablet']);

        $this->assertSame(
            'device-uid-tablet',
            $this->tokens()->deviceForIdentity($device)?->device_uid,
        );

        $this->assertNull($this->tokens()->deviceForIdentity(null));
    }
}
