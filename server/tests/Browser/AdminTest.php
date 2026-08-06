<?php

namespace Tests\Browser;

use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\User;
use Laravel\Dusk\Browser;
use Tests\Concerns\SeedsBrowserFixtures;
use Tests\DuskTestCase;

/**
 * The admin publishing tool — WP8.
 *
 * `users.is_admin` is the whole authorisation model and `EnsureAdmin` is the
 * whole enforcement (DLC_SERVER.md §10.2). In the browser it has two halves
 * that have to agree, and only one of them is server-side:
 *
 * - `/admin/*` answers a **404**, not a 403, so an ordinary parent who guesses
 *   the URL learns nothing.
 * - `AppSidebar.vue` renders no nav entry unless `auth.user.is_admin`, so
 *   there is nothing to guess from in the first place.
 *
 * The second is Vue reading an Inertia prop. If `HandleInertiaRequests` ever
 * stopped sharing `is_admin`, the section would simply vanish for the
 * operator — no error, no failing route test. That is what this file is for.
 */
class AdminTest extends DuskTestCase
{
    use SeedsBrowserFixtures;

    public function test_an_ordinary_parent_sees_no_admin_entry_in_the_sidebar(): void
    {
        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->create())
                ->visit('/dashboard')
                ->waitFor('[data-test="sidebar-menu-button"]')
                ->assertSee('Dashboard')
                ->assertDontSee('Entitlements')
                ->assertMissing('a[href="/admin/packs"]')
                ->assertMissing('a[href="/admin/entitlements"]');
        });
    }

    public function test_an_ordinary_parent_guessing_the_url_gets_a_404(): void
    {
        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->create())
                ->visit('/admin/packs')
                ->waitForText('404')
                // Not a 403: the page must not confirm that a packs section
                // exists at all.
                ->assertDontSee('Every pack, drafts included')
                ->visit('/admin/entitlements')
                ->waitForText('404')
                ->assertDontSee('Grant a pack by parent email');
        });
    }

    public function test_an_admin_gets_the_nav_entries_and_the_pack_list(): void
    {
        Pack::factory()->create(['slug' => 'meadow-mates', 'title' => 'Meadow Mates']);

        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->admin()->create())
                ->visit('/dashboard')
                ->waitFor('a[href="/admin/packs"]')
                ->assertSee('Entitlements')
                ->clickLink('Packs')
                ->waitForText('Every pack, drafts included')
                ->assertSee('Meadow Mates')
                ->assertSee('meadow-mates')
                ->assertSee('nothing published yet')
                ->assertSee('draft');
        });
    }

    public function test_an_admin_reserves_a_slug_with_the_new_pack_form(): void
    {
        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->admin()->create())
                ->visit('/admin/packs')
                ->waitForText('No packs yet')
                ->type('#slug', 'coyote-book')
                ->type('#title', 'The Coyote Book')
                ->clickAtXPath("//button[normalize-space()='Create']")
                ->waitForText('Pack created.')
                // Straight to the pack's own page, which is where a version
                // gets uploaded.
                ->waitForLocation('/admin/packs/coyote-book')
                ->assertSee('The Coyote Book')
                ->assertSee('No versions yet.');
        });

        $pack = Pack::query()->sole();

        $this->assertSame('coyote-book', $pack->slug);
        // A new pack is a draft. Reserving a slug is not publishing anything.
        $this->assertSame(Pack::STATUS_DRAFT, $pack->status);
    }

    public function test_an_admin_publishes_a_draft_version(): void
    {
        // Imported through the real publisher, as a draft: content-addressed
        // assets, a zip and an unpacked files/ tree all exist on the Dusk
        // storage tree, exactly as an upload would have left them.
        $version = $this->seedDraftPack();

        $this->assertNull($version->published_at);
        $this->assertSame(Pack::STATUS_DRAFT, $version->pack->status);

        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->admin()->create())
                ->visit('/admin/packs/meadow-mates')
                ->waitForText('v1')
                ->assertSee('draft')
                ->clickAtXPath("//button[normalize-space()='Publish']")
                ->waitForText('v1 published.')
                // Published versions are immutable, so the form that would
                // publish it again is gone.
                //
                // Asserted on the form and not on the words: this page's own
                // prose contains both "draft" ("filed as a draft") and
                // "Publish" ("Published versions are immutable"), so
                // `assertDontSee` on either can never come true.
                ->waitUntilMissing('form[action="/admin/packs/meadow-mates/versions/1/publish"]');
        });

        $this->assertNotNull(PackVersion::query()->sole()->published_at);
        $this->assertSame(Pack::STATUS_PUBLISHED, Pack::query()->sole()->status);
    }

    public function test_an_admin_grants_a_promo_entitlement_by_email(): void
    {
        $parent = User::factory()->create(['email' => 'parent@example.com']);
        $pack = Pack::factory()->create(['slug' => 'meadow-mates', 'title' => 'Meadow Mates']);

        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->admin()->create())
                ->visit('/admin/entitlements')
                ->waitForText('Nothing granted yet.')
                ->type('#email', 'parent@example.com')
                ->select('#pack_slug', 'meadow-mates')
                ->select('#source', 'promo')
                ->clickAtXPath("//button[normalize-space()='Grant']")
                ->waitForText('Entitlement granted.')
                ->waitUntilMissingText('Nothing granted yet.')
                ->assertSee('parent@example.com')
                ->assertSee('live');
        });

        $entitlement = Entitlement::query()->sole();

        $this->assertSame($parent->id, $entitlement->user_id);
        $this->assertSame($pack->id, $entitlement->pack_id);
        $this->assertSame(Entitlement::SOURCE_PROMO, $entitlement->source);
        $this->assertNull($entitlement->revoked_at);
    }

    public function test_granting_to_an_address_with_no_account_is_a_field_error(): void
    {
        Pack::factory()->create(['slug' => 'meadow-mates', 'title' => 'Meadow Mates']);

        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->admin()->create())
                ->visit('/admin/entitlements')
                ->waitFor('#email')
                ->type('#email', 'nobody@example.com')
                ->select('#pack_slug', 'meadow-mates')
                ->clickAtXPath("//button[normalize-space()='Grant']")
                // Beside the field the operator mistyped, not a red banner
                // across the top: they got one of two inputs wrong and the
                // form should say which.
                ->waitForText('No account has that email address.')
                ->assertSee('Nothing granted yet.');
        });

        $this->assertDatabaseCount('entitlements', 0);
    }
}
