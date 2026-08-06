<?php

namespace Tests\Unit;

use App\Models\Device;
use App\Models\User;
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
        $user = User::factory()->create();

        $user->createToken('device-uid', $this->tokens()->abilities(), $at);

        /** @var PersonalAccessToken $token */
        $token = $user->tokens()->firstOrFail();

        return $token;
    }

    public function test_the_abilities_are_exactly_the_three_the_game_needs(): void
    {
        $this->assertSame(
            ['save:sync', 'entitlements:read', 'packs:download'],
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
        $user = User::factory()->create();
        $user->createToken('device-uid', $this->tokens()->abilities());

        /** @var PersonalAccessToken $token */
        $token = $user->tokens()->firstOrFail();

        $this->assertFalse($this->tokens()->shouldSlide($token));
    }

    public function test_a_device_is_only_touched_once_it_is_stale(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $seenAt = CarbonImmutable::parse('2026-08-06 11:55:00');
        $device = Device::factory()->create(['last_seen_at' => $seenAt]);

        $this->tokens()->touchDevice($device);
        $this->assertTrue($device->fresh()->last_seen_at->equalTo($seenAt));

        // Forced, e.g. by a sign-in or an explicit refresh.
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

    public function test_a_token_is_matched_to_its_device_by_name(): void
    {
        $user = User::factory()->create();
        Device::factory()->for($user)->create(['device_uid' => 'device-uid-tablet']);
        $user->createToken('device-uid-tablet', $this->tokens()->abilities(), CarbonImmutable::now()->addDay());

        /** @var PersonalAccessToken $token */
        $token = $user->tokens()->firstOrFail();

        $this->assertSame('device-uid-tablet', $this->tokens()->deviceFor($user, $token)?->device_uid);
    }

    public function test_devices_are_flagged_with_whether_a_live_token_exists(): void
    {
        $user = User::factory()->create();
        Device::factory()->for($user)->create(['device_uid' => 'live']);
        Device::factory()->for($user)->create(['device_uid' => 'revoked']);
        Device::factory()->for($user)->create(['device_uid' => 'stale']);

        $user->createToken('live', ['save:sync'], CarbonImmutable::now()->addDay());
        $user->createToken('stale', ['save:sync'], CarbonImmutable::now()->subDay());

        $flags = $this->tokens()->devicesFor($user)
            ->mapWithKeys(fn (Device $device) => [$device->device_uid => $device->is_signed_in])
            ->all();

        $this->assertTrue($flags['live']);
        $this->assertFalse($flags['revoked']);
        $this->assertFalse($flags['stale']);
    }
}
