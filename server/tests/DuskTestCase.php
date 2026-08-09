<?php

namespace Tests;

use Facebook\WebDriver\Chrome\ChromeOptions;
use Facebook\WebDriver\Exception\TimeoutException;
use Facebook\WebDriver\Remote\DesiredCapabilities;
use Facebook\WebDriver\Remote\RemoteWebDriver;
use Facebook\WebDriver\WebDriverBy;
use Illuminate\Foundation\Testing\DatabaseMigrations;
use Illuminate\Support\Collection;
use Laravel\Dusk\Browser;
use Laravel\Dusk\TestCase as BaseTestCase;
use PHPUnit\Framework\Attributes\BeforeClass;

/**
 * The base for every browser test — WP8.
 *
 * ### Why `DatabaseMigrations` and not `RefreshDatabase`
 *
 * `RefreshDatabase` wraps each test in a transaction and rolls it back. That
 * works because the assertions and the code under test share one connection.
 * A Dusk test does not: the browser talks to a *separate* `php artisan serve`
 * process, which would never see anything written inside this process's open
 * transaction. So the database is a real file (`.env.dusk.local`) and it is
 * migrated fresh between tests instead — slower, and the only thing that is
 * actually true.
 *
 * The same fact rules out `Storage::fake()` anywhere in this suite: a fake disk
 * only exists in this process's container. Where a test needs bytes on a disk
 * — a paint layer, a published pack — it writes real files, which is what the
 * Dusk private storage tree (`storage/app/private/dusk`) exists for.
 */
abstract class DuskTestCase extends BaseTestCase
{
    use DatabaseMigrations;

    /**
     * Prepare for Dusk test execution.
     */
    #[BeforeClass]
    public static function prepare(): void
    {
        if (! static::runningInSail()) {
            static::startChromeDriver(['--port=9515']);
        }
    }

    /**
     * Create the RemoteWebDriver instance.
     */
    protected function driver(): RemoteWebDriver
    {
        /*
         * A fixed 1400x1000 window rather than `--start-maximized`: the
         * dashboard's sidebar collapses below the `md` breakpoint, and the
         * logout control lives inside it. A test whose result depends on how
         * wide the developer's monitor happens to be is not a test.
         */
        $options = (new ChromeOptions)->addArguments(collect([
            '--window-size=1400,1000',
            '--disable-search-engine-choice-screen',
            '--disable-smooth-scrolling',
            /*
             * The one that took a day to find. Submit the login form
             * successfully once and Chrome's password manager raises its
             * "Save password?" bubble — browser UI, outside the page, and
             * invisible in headless. It takes browser-level input focus and
             * **every subsequent keystroke in the whole session goes to it
             * instead of the page**.
             *
             * The symptom is maddening: `document.hasFocus()` is true, the
             * field is `document.activeElement`, WebDriver's send-keys returns
             * success — and the input stays empty. Not `type()`, not `keys()`,
             * not focusing via JavaScript, not even a `refresh()` gets it
             * back. Only the login form triggers it, because it is the one
             * carrying `autocomplete="current-password"`; registration's
             * `new-password` fields do not.
             */
            '--disable-save-password-bubble',
            '--disable-features=PasswordLeakDetection,AutofillServerCommunication',
        ])->unless($this->hasHeadlessDisabled(), function (Collection $items) {
            return $items->merge([
                '--disable-gpu',
                '--headless=new',
            ]);
        })->all());

        // Belt and braces on the same problem: never offer to save, and never
        // run the leak check that pops its own bubble.
        $options->setExperimentalOption('prefs', [
            'credentials_enable_service' => false,
            'profile.password_manager_enabled' => false,
            'profile.password_manager_leak_detection' => false,
        ]);

        /*
         * `goog:loggingPrefs` is not set by Dusk's own scaffolding, and
         * without it `storeConsoleLog()` writes an empty file — which is
         * indistinguishable from "no JavaScript errors" exactly when a test is
         * failing because of one. Turning it on makes `tests/Browser/console`
         * worth reading.
         */
        return RemoteWebDriver::create(
            $_ENV['DUSK_DRIVER_URL'] ?? env('DUSK_DRIVER_URL') ?? 'http://localhost:9515',
            DesiredCapabilities::chrome()
                ->setCapability(ChromeOptions::CAPABILITY, $options)
                ->setCapability('goog:loggingPrefs', ['browser' => 'ALL'])
        );
    }

    /**
     * Determine whether the Dusk command has disabled headless mode.
     */
    protected function hasHeadlessDisabled(): bool
    {
        return isset($_SERVER['DUSK_HEADLESS_DISABLED']) ||
               isset($_ENV['DUSK_HEADLESS_DISABLED']);
    }

    /**
     * Start every test from a browser with no memory of the last one.
     *
     * Dusk reuses one Chrome session across the whole suite while
     * `DatabaseMigrations` drops the `sessions` table between tests. A cookie
     * left pointing at a session that no longer exists is not merely stale —
     * it is a signed-in-looking browser attached to nothing, and the failure it
     * produces is nowhere near the test that caused it.
     */
    protected function blank(Browser $browser): Browser
    {
        $browser->visit('/');

        // Straight at the driver: Dusk's own `deleteCookie()` takes a name,
        // and the point here is to leave nothing behind whatever it was called.
        $browser->driver->manage()->deleteAllCookies();

        return $browser;
    }

    /**
     * Type into a field and do not move on until the field really holds it.
     *
     * This exists because of how *quietly* a lost keystroke fails here. Every
     * form on the auth pages uses **uncontrolled** inputs — `name=` with no
     * `v-model`, read back out of the DOM on submit — and the fields are
     * `required`. So an input that ends up empty does not produce an error:
     * the browser simply refuses to submit, with no request, no validation
     * message, no console output and a byte-identical DOM. The test then times
     * out somewhere else entirely, waiting for a response the server was never
     * asked for.
     *
     * The known cause of an empty field is documented on {@see driver()} (the
     * password-manager bubble) and is fixed there. This is the tripwire: read
     * the value back before moving on, so if anything ever swallows input
     * again the failure names the field instead of surfacing five steps later.
     *
     * It is a wait condition, not a sleep — it cannot go green on an empty
     * field.
     *
     * `$field` is a CSS selector, not a field name: the value has to be read
     * back with `value()`, which does not do `type()`'s name-attribute lookup.
     */
    protected function fill(Browser $browser, string $field, string $value): Browser
    {
        $browser->waitFor($field);

        $browser->waitUsing(10, 100, function () use ($browser, $field, $value): bool {
            if ($browser->value($field) === $value) {
                return true;
            }

            $browser->type($field, $value);

            return $browser->value($field) === $value;
        }, "The field [{$field}] would not hold the value [{$value}] — something is re-rendering it.");

        return $browser;
    }

    /**
     * Click something, and keep clicking until it has actually had an effect.
     *
     * A click that lands before reka-ui has finished wiring a trigger is
     * accepted by WebDriver and then does nothing at all — `click()` reports
     * success either way, so there is nothing to assert on but the *result*.
     * Retrying until the thing the click was for appears is the only honest
     * way to wait for it, and since the exit condition is the appearance of
     * `$until`, this cannot go green on a control that never worked.
     */
    protected function clickUntil(Browser $browser, string $selector, string $until): Browser
    {
        $browser->waitFor($selector);

        $present = fn (): bool => count(
            $browser->driver->findElements(WebDriverBy::cssSelector($until))
        ) > 0;

        /*
         * Click, then give it a moment before deciding the click failed.
         *
         * Polling and re-clicking in one tight loop is worse than useless on a
         * *toggle*: the menu opens, the next poll runs before it is on screen,
         * and the retry closes it again. Three deliberate attempts, each with
         * its own settle window.
         */
        for ($attempt = 0; $attempt < 3 && ! $present(); $attempt++) {
            $browser->click($selector);

            try {
                $browser->waitUsing(3, 100, $present);
            } catch (TimeoutException) {
                // Try again; the assertion below is what decides.
            }
        }

        return $browser->waitFor($until);
    }

    /**
     * Open `/login` and wait until the form is there.
     *
     * The passkey block that used to rearrange this page went with the parent
     * accounts; nothing renders above the form asynchronously any more, so
     * waiting for the email field is enough.
     */
    protected function visitLogin(Browser $browser): Browser
    {
        return $browser->visit('/login')
            ->waitForText('Log in to your account')
            ->waitFor('input[name="email"]');
    }

    /**
     * Open the sidebar's account menu, where "Log out" lives.
     */
    protected function openAccountMenu(Browser $browser): Browser
    {
        return $this->clickUntil(
            $browser,
            '[data-test="sidebar-menu-button"]',
            '[data-test="logout-button"]',
        );
    }
}
