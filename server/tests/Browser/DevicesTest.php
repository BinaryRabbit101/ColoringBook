<?php

namespace Tests\Browser;

use App\Models\Device;
use App\Models\User;
use Carbon\CarbonImmutable;
use Laravel\Dusk\Browser;
use Tests\DuskTestCase;

/**
 * The devices page — WP8.
 *
 * "Sign this device out" is the one control in the dashboard that reaches into
 * the game: it deletes the Sanctum tokens named after the install's
 * `device_uid`, and the next API call from that tablet 401s into offline mode
 * (DLC_SERVER.md §4.2). The assertion that matters is therefore not "the row
 * went grey" but **the token row is gone** — the button is a lie otherwise.
 *
 * The device row itself survives on purpose. It is the record that the install
 * exists, and it lights up again the moment somebody signs in on it.
 */
class DevicesTest extends DuskTestCase
{
    /**
     * A device signed in the way `POST /auth/token` signs one in: a `devices`
     * row plus a token *named* after its `device_uid`, which is the only link
     * between Sanctum's table and this page.
     */
    private function signedInDevice(User $user, string $deviceUid, string $name): Device
    {
        $device = Device::factory()->for($user)->create([
            'device_uid' => $deviceUid,
            'device_name' => $name,
            'platform' => 'android',
            'last_seen_at' => CarbonImmutable::now()->subMinutes(20),
        ]);

        /** @var array<int, string> $abilities */
        $abilities = config('coloringbook.token.abilities');

        $user->createToken($deviceUid, $abilities, CarbonImmutable::now()->addDays(90));

        return $device;
    }

    public function test_a_signed_in_device_is_listed(): void
    {
        $user = User::factory()->create();
        $this->signedInDevice($user, 'device-uid-tablet', "Ivy's tablet");

        $this->browse(function (Browser $browser) use ($user): void {
            $browser->loginAs($user)
                ->visit('/settings/devices')
                ->waitForText("Ivy's tablet")
                ->assertSee('android')
                ->assertDontSee('No device has signed in yet.')
                ->assertDontSee('Signed out');
        });
    }

    public function test_signing_a_device_out_revokes_its_token(): void
    {
        $user = User::factory()->create();
        $device = $this->signedInDevice($user, 'device-uid-tablet', "Ivy's tablet");

        $this->assertDatabaseCount('personal_access_tokens', 1);

        $this->browse(function (Browser $browser) use ($user, $device): void {
            $browser->loginAs($user)
                ->visit('/settings/devices')
                ->waitFor("[data-test=\"sign-out-device-{$device->ulid}\"]")
                ->click("[data-test=\"sign-out-device-{$device->ulid}\"]")
                ->waitForText('Device signed out.')
                // No button left to press, and the row says so.
                ->waitForText('Signed out')
                ->assertMissing("[data-test=\"sign-out-device-{$device->ulid}\"]");
        });

        // The whole mechanism: the token is gone, so the tablet's next call
        // 401s and the game drops into offline mode silently.
        $this->assertDatabaseCount('personal_access_tokens', 0);

        // The device row is not: it is the history of the install.
        $this->assertDatabaseHas('devices', [
            'id' => $device->id,
            'device_uid' => 'device-uid-tablet',
        ]);
    }

    public function test_signing_one_device_out_leaves_the_others_signed_in(): void
    {
        $user = User::factory()->create();
        $tablet = $this->signedInDevice($user, 'device-uid-tablet', "Ivy's tablet");
        $this->signedInDevice($user, 'device-uid-laptop', 'Kitchen laptop');

        $this->browse(function (Browser $browser) use ($user, $tablet): void {
            $browser->loginAs($user)
                ->visit('/settings/devices')
                ->waitFor("[data-test=\"sign-out-device-{$tablet->ulid}\"]")
                ->click("[data-test=\"sign-out-device-{$tablet->ulid}\"]")
                ->waitForText('Device signed out.')
                ->assertSee('Kitchen laptop');
        });

        $this->assertSame(1, $user->tokens()->count());
        $this->assertSame('device-uid-laptop', $user->tokens()->sole()->name);
    }

    public function test_an_account_that_has_never_signed_in_says_so(): void
    {
        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->create())
                ->visit('/settings/devices')
                ->waitForText('No device has signed in yet.');
        });
    }
}
