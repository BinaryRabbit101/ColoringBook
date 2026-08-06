<?php

namespace Tests\Browser;

use App\Models\User;
use Laravel\Dusk\Browser;
use Tests\DuskTestCase;

/**
 * Creating a parent account, in a real browser — WP8.
 *
 * The guardian confirmation is the reason this is worth a browser test rather
 * than only the HTTP one in `tests/Feature/Auth/RegistrationTest.php`. It is
 * the whole of the app's age-gate (DLC_SERVER.md §4.1), it is a checkbox that
 * is *not* a `<input type="checkbox">` — reka-ui renders a `<button
 * role="checkbox">` with a visually hidden input behind it — and a component
 * upgrade that stopped that hidden input from being submitted would leave a
 * form that looks exactly right and silently cannot be completed. Nothing
 * short of a browser can catch that.
 */
class RegistrationTest extends DuskTestCase
{
    private const PASSWORD = 'grown-up-secret';

    public function test_the_form_will_not_submit_without_the_guardian_promise(): void
    {
        $this->browse(function (Browser $browser): void {
            $this->blank($browser)
                ->visit('/register')
                ->waitForText('Create an account')
                ->type('name', 'Ada Guardian')
                ->type('email', 'ada@example.com')
                ->type('password', self::PASSWORD)
                ->type('password_confirmation', self::PASSWORD)
                // Everything filled in *except* the promise.
                ->assertAttribute('#is_guardian', 'data-state', 'unchecked')
                ->click('[data-test="register-user-button"]')
                ->waitForText('Please confirm you are the parent or guardian.')
                ->assertPathIs('/register');
        });

        $this->assertDatabaseCount('users', 0);
    }

    public function test_confirming_it_creates_the_account_and_lands_on_the_dashboard(): void
    {
        $this->browse(function (Browser $browser): void {
            $this->blank($browser)
                ->visit('/register')
                ->waitForText('Create an account')
                ->type('name', 'Ada Guardian')
                ->type('email', 'ada@example.com')
                ->type('password', self::PASSWORD)
                ->type('password_confirmation', self::PASSWORD)
                // The checkbox is a button; `check()` would look for an input
                // it can click, and the only input here is hidden.
                ->click('#is_guardian')
                ->assertAttribute('#is_guardian', 'data-state', 'checked')
                ->click('[data-test="register-user-button"]')
                ->waitForLocation('/dashboard')
                ->assertSee('Ada Guardian');
        });

        $user = User::query()->sole();

        $this->assertSame('ada@example.com', $user->email);

        // The whole PII footprint is the parent's name, email and password
        // (§4.1). The promise is checked and then forgotten — it is not a
        // column.
        $this->assertFalse($user->is_admin);
        $this->assertArrayNotHasKey('is_guardian', $user->getAttributes());
    }

    public function test_a_second_account_cannot_take_an_email_that_is_taken(): void
    {
        User::factory()->create(['email' => 'ada@example.com']);

        $this->browse(function (Browser $browser): void {
            $this->blank($browser)
                ->visit('/register')
                ->waitForText('Create an account')
                ->type('name', 'Someone Else')
                ->type('email', 'ada@example.com')
                ->type('password', self::PASSWORD)
                ->type('password_confirmation', self::PASSWORD)
                ->click('#is_guardian')
                ->click('[data-test="register-user-button"]')
                ->waitForText('has already been taken')
                ->assertPathIs('/register');
        });

        $this->assertDatabaseCount('users', 1);
    }
}
