<?php

namespace Tests\Feature\Settings;

use App\Models\Device;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

/**
 * The parent dashboard's devices page: see what has signed in, sign one out
 * (DLC_SERVER.md §4.2).
 */
class DevicesPageTest extends TestCase
{
    use RefreshDatabase;

    public function test_the_page_lists_devices_with_their_platform_and_last_seen(): void
    {
        $user = User::factory()->create();
        $this->issueDeviceToken($user, 'device-uid-tablet');

        Device::query()->update([
            'device_name' => "Ivy's tablet",
            'platform' => 'android',
            'last_seen_at' => CarbonImmutable::parse('2026-08-01 09:00:00'),
        ]);

        $this->actingAs($user)
            ->get(route('devices.edit'))
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('settings/Devices')
                ->has('devices', 1)
                ->where('devices.0.device_name', "Ivy's tablet")
                ->where('devices.0.platform', 'android')
                ->where('devices.0.is_signed_in', true)
                ->has('devices.0.last_seen_at'),
            );
    }

    public function test_a_device_with_no_live_token_shows_as_signed_out(): void
    {
        $user = User::factory()->create();
        Device::factory()->for($user)->create();

        $this->actingAs($user)
            ->get(route('devices.edit'))
            ->assertOk()
            ->assertInertia(fn ($page) => $page->where('devices.0.is_signed_in', false));
    }

    public function test_an_expired_token_also_shows_as_signed_out(): void
    {
        $this->travelTo(CarbonImmutable::parse('2026-08-06 12:00:00'));

        $user = User::factory()->create();
        $this->issueDeviceToken($user, 'device-uid-tablet');

        $this->travelTo(CarbonImmutable::parse('2026-12-06 12:00:00'));

        $this->actingAs($user)
            ->get(route('devices.edit'))
            ->assertOk()
            ->assertInertia(fn ($page) => $page->where('devices.0.is_signed_in', false));
    }

    public function test_the_page_only_shows_the_parents_own_devices(): void
    {
        $user = User::factory()->create();
        Device::factory()->for(User::factory())->create();

        $this->actingAs($user)
            ->get(route('devices.edit'))
            ->assertOk()
            ->assertInertia(fn ($page) => $page->has('devices', 0));
    }

    public function test_signing_a_device_out_kills_that_devices_api_access(): void
    {
        $user = User::factory()->create();
        $tablet = $this->issueDeviceToken($user, 'device-uid-tablet');
        $laptop = $this->issueDeviceToken($user, 'device-uid-laptop');

        $this->withToken($tablet)->getJson('/api/v1/me')->assertOk();

        $device = Device::query()->where('device_uid', 'device-uid-tablet')->sole();

        $this->actingAs($user)
            ->delete(route('devices.destroy', $device->ulid))
            ->assertRedirect(route('devices.edit'));

        $this->forgetResolvedGuards()->withToken($tablet)->getJson('/api/v1/me')
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'UNAUTHENTICATED');

        // The other device in the household is untouched.
        $this->forgetResolvedGuards()->withToken($laptop)->getJson('/api/v1/me')->assertOk();

        // The row stays: it is the record that the install exists.
        $this->assertDatabaseCount('devices', 2);
    }

    public function test_a_parent_cannot_sign_out_another_accounts_device(): void
    {
        $user = User::factory()->create();
        $stranger = User::factory()->create();
        $this->issueDeviceToken($stranger, 'device-uid-stranger');

        $device = Device::query()->where('device_uid', 'device-uid-stranger')->sole();

        $this->actingAs($user)
            ->delete(route('devices.destroy', $device->ulid))
            ->assertNotFound();

        $this->assertSame(1, $stranger->tokens()->count());
    }

    public function test_the_page_needs_a_signed_in_parent(): void
    {
        $this->get(route('devices.edit'))->assertRedirect(route('login'));
    }

    public function test_a_game_token_cannot_revoke_a_device(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user, 'device-uid-tablet');
        $device = Device::query()->sole();

        // Revocation is dashboard-only: a leaked user://auth.json must not be
        // able to lock the household out (design §4.2).
        $this->withToken($bearer)
            ->deleteJson(route('devices.destroy', $device->ulid))
            ->assertUnauthorized();

        $this->assertSame(1, $user->tokens()->count());
    }
}
