<?php

namespace Tests\Browser;

use App\Models\User;
use Laravel\Dusk\Browser;
use Tests\DuskTestCase;

/**
 * Signing in and signing out — WP8.
 *
 * Logging out is the half that needs a browser: the control is not on the
 * page, it is inside the sidebar's account dropdown, and it is a `<Link
 * as="button">` that Inertia turns into a POST. A route test proves the POST
 * works; only this proves a parent can find the button that sends it.
 */
class AuthenticationTest extends DuskTestCase
{
    public function test_a_parent_signs_in_with_their_password(): void
    {
        $user = User::factory()->create([
            'name' => 'Ada Guardian',
            'email' => 'ada@example.com',
        ]);

        $this->browse(function (Browser $browser) use ($user): void {
            $browser = $this->visitLogin($this->blank($browser));

            $this->fill($browser, 'input[name="email"]', $user->email);
            // UserFactory hashes 'password' for every user it makes.
            $this->fill($browser, 'input[name="password"]', 'password');

            $browser->click('[data-test="login-button"]')
                ->waitForLocation('/dashboard')
                ->assertSee('Ada Guardian');
        });
    }

    public function test_the_wrong_password_keeps_them_on_the_login_page(): void
    {
        $user = User::factory()->create(['email' => 'ada@example.com']);

        $this->browse(function (Browser $browser) use ($user): void {
            $browser = $this->visitLogin($this->blank($browser));

            $this->fill($browser, 'input[name="email"]', $user->email);
            $this->fill($browser, 'input[name="password"]', 'not-the-password');

            $browser->click('[data-test="login-button"]')
                ->waitForText('These credentials do not match our records.')
                ->assertPathIs('/login');
        });
    }

    public function test_signing_out_from_the_account_menu_ends_the_session(): void
    {
        $user = User::factory()->create();

        $this->browse(function (Browser $browser) use ($user): void {
            $browser->loginAs($user)
                ->visit('/dashboard')
                ->waitFor('[data-test="sidebar-menu-button"]');

            $this->openAccountMenu($browser)
                ->click('[data-test="logout-button"]')
                ->waitForLocation('/')
                // And the session really is gone, not merely navigated away
                // from: the dashboard bounces back to the login page.
                ->visit('/dashboard')
                ->waitForLocation('/login')
                ->assertSee('Log in to your account');
        });
    }

    public function test_the_dashboard_is_not_reachable_signed_out(): void
    {
        $this->browse(function (Browser $browser): void {
            $this->blank($browser)
                ->visit('/dashboard')
                ->waitForLocation('/login')
                ->assertSee('Log in to your account');
        });
    }
}
