<?php

namespace Tests\Browser;

use App\Models\ChildProfile;
use App\Models\PaintLayer;
use App\Models\RetainedPaintLayer;
use App\Models\User;
use App\Services\PaintStorage;
use Laravel\Dusk\Browser;
use Tests\Concerns\SeedsBrowserFixtures;
use Tests\DuskTestCase;

/**
 * "Restore the older picture" — WP8.
 *
 * The failure this page exists for is the only genuinely upsetting one in the
 * whole sync design: a child's finished picture disappearing because a second
 * device uploaded over it (DLC_SERVER.md §6.3). Everything here is about the
 * button working, and about it being a grown-up's button on a grown-up's
 * screen — a five year old is never shown the choice.
 *
 * Unlike the Feature suite's version of this, the bytes are **real files on
 * the paint disk** (see {@see SeedsBrowserFixtures}), because a restore is a
 * swap of two files and asserting it against a faked disk in a process the
 * browser never talks to would prove nothing about the page.
 */
class PicturesTest extends DuskTestCase
{
    use SeedsBrowserFixtures;

    public function test_a_page_with_nothing_to_restore_is_not_listed(): void
    {
        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->create())
                ->visit('/settings/pictures')
                ->waitForText('Nothing to restore.');
        });
    }

    public function test_a_contested_page_is_listed_with_its_older_version(): void
    {
        $user = User::factory()->create();
        $this->seedContestedPage($user);

        $this->browse(function (Browser $browser) use ($user): void {
            $browser->loginAs($user)
                ->visit('/settings/pictures')
                ->waitForText('coyote-2026')
                ->assertDontSee('Nothing to restore.')
                // The account shelf, not a child's.
                ->assertSee('Everyone')
                // 1-based for a human, matching the file on disk.
                ->assertSee('Page 1')
                ->assertSee('Restore the older picture');
        });
    }

    public function test_a_childs_book_is_listed_under_their_name(): void
    {
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create(['nickname' => 'Ivy']);

        $this->seedContestedPage($user, profile: $profile);

        $this->browse(function (Browser $browser) use ($user): void {
            $browser->loginAs($user)
                ->visit('/settings/pictures')
                ->waitForText('coyote-2026')
                ->assertSee('Ivy')
                ->assertDontSee('Everyone');
        });
    }

    public function test_pressing_restore_swaps_the_two_versions_over(): void
    {
        $user = User::factory()->create();
        $retained = $this->seedContestedPage($user);
        $storage = app(PaintStorage::class);

        $live = "{$user->ulid}/coyote-2026/page_01.png";
        $this->assertSame($this->paintPng('evening'), $storage->disk()->get($live));

        $this->browse(function (Browser $browser) use ($user, $retained): void {
            $browser->loginAs($user)
                ->visit('/settings/pictures')
                ->waitFor("[data-test=\"restore-{$retained->ulid}\"]")
                ->click("[data-test=\"restore-{$retained->ulid}\"]")
                ->waitForText('Picture restored.')
                // That retained row is gone — but the page is still listed,
                // because a restore is a *swap*: the version it displaced took
                // its place in retention and is restorable in turn. "Nothing
                // to restore" would be the wrong assertion here.
                ->waitUntilMissing("[data-test=\"restore-{$retained->ulid}\"]")
                ->assertSee('Restore the older picture');
        });

        // The morning picture is back where the game will fetch it…
        $this->assertSame($this->paintPng('morning'), $storage->disk()->get($live));

        $layer = PaintLayer::query()->sole();
        $this->assertSame(hash('sha256', $this->paintPng('morning')), $layer->sha256);
        $this->assertSame($live, $layer->storage_path);
        $this->assertSame(3, $layer->revision);

        // …and the evening picture took its place in retention, so the button
        // can never be the thing that loses a picture.
        $demoted = RetainedPaintLayer::query()->sole();
        $this->assertSame(hash('sha256', $this->paintPng('evening')), $demoted->sha256);
        $this->assertSame("{$user->ulid}/coyote-2026/page_01.2.png", $demoted->storage_path);
        $this->assertSame($this->paintPng('evening'), $storage->disk()->get($demoted->storage_path));
    }

    public function test_pressing_restore_twice_puts_everything_back(): void
    {
        $user = User::factory()->create();
        $retained = $this->seedContestedPage($user);
        $storage = app(PaintStorage::class);

        $this->browse(function (Browser $browser) use ($user, $retained): void {
            $browser->loginAs($user)
                ->visit('/settings/pictures')
                ->waitFor("[data-test=\"restore-{$retained->ulid}\"]")
                ->click("[data-test=\"restore-{$retained->ulid}\"]")
                ->waitForText('Picture restored.')
                ->waitUntilMissing("[data-test=\"restore-{$retained->ulid}\"]");

            // The version it demoted is now the restorable one — a mis-click
            // is always recoverable by pressing the button again.
            $demoted = RetainedPaintLayer::query()->sole();

            $browser->visit('/settings/pictures')
                ->waitFor("[data-test=\"restore-{$demoted->ulid}\"]")
                ->click("[data-test=\"restore-{$demoted->ulid}\"]")
                ->waitForText('Picture restored.');
        });

        $this->assertSame(
            $this->paintPng('evening'),
            $storage->disk()->get("{$user->ulid}/coyote-2026/page_01.png"),
        );

        $this->assertDatabaseCount('retained_paint_layers', 1);
    }

    public function test_another_households_picture_is_not_reachable(): void
    {
        $owner = User::factory()->create();
        $retained = $this->seedContestedPage($owner);

        $this->browse(function (Browser $browser) use ($retained): void {
            // A stranger signed in to their own account cannot even see it —
            // and a hand-built URL is a 404 rather than a 403, so an id that
            // is not yours is never confirmed to exist.
            $browser->loginAs(User::factory()->create())
                ->visit('/settings/pictures')
                ->waitForText('Nothing to restore.')
                ->assertDontSee($retained->ulid);
        });

        $this->assertNotNull($retained->fresh());
    }
}
