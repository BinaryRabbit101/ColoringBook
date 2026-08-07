<?php

namespace Tests\Browser;

use App\Models\AuthoredBook;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\User;
use Laravel\Dusk\Browser;
use Tests\Concerns\SeedsBrowserFixtures;
use Tests\DuskTestCase;

/**
 * Web authoring in a real browser — BL-24 (§10.3), following WP8's patterns.
 *
 * The Pest suite already proves the endpoints. What only a browser can show is
 * that the three screens hold together: the book list, the book with its pages
 * and its one publish button, and the page editor with the region overlay and
 * the validation report. Those are Vue reading Inertia props, and a prop that
 * stopped being shared would simply make the section useless with nothing
 * failing anywhere else.
 *
 * **No page is uploaded here.** The mapping job shells out to headless Godot in
 * the `php artisan serve` process, which has no fake to bind and (deliberately)
 * no engine configured in `.env.dusk.local`; `seedAuthoredBook()` therefore
 * seeds the state a finished job leaves behind. The pipeline itself is covered
 * by `MappingPipelineIntegrationTest`, which is opt-in for exactly this reason.
 */
class AuthoringTest extends DuskTestCase
{
    use SeedsBrowserFixtures;

    public function test_an_ordinary_parent_sees_no_books_entry_and_gets_a_404(): void
    {
        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->create())
                ->visit('/dashboard')
                ->waitFor('[data-test="sidebar-menu-button"]')
                ->assertMissing('a[href="/admin/books"]')
                ->visit('/admin/books')
                ->waitForText('404')
                // Not a 403: the page must not confirm an authoring section
                // exists at all.
                ->assertDontSee('Colouring books authored here');
        });
    }

    public function test_an_admin_reaches_the_book_list_from_the_sidebar(): void
    {
        $this->seedAuthoredBook();

        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->admin()->create())
                ->visit('/dashboard')
                ->waitFor('a[href="/admin/books"]')
                ->clickLink('Books')
                ->waitForText('Colouring books authored here')
                ->assertSee('Coyote')
                ->assertSee('coyote-2026')
                ->assertSee('never published')
                ->assertSee('ready to publish');
        });
    }

    public function test_an_admin_creates_a_book_and_lands_on_it(): void
    {
        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->admin()->create())
                ->visit('/admin/books')
                ->waitForText('No books yet')
                ->type('#book_uid', 'badger-2026')
                ->type('#title', 'Badger')
                ->clickAtXPath("//button[normalize-space()='Create']")
                ->waitForText('Book created.')
                ->waitForLocation('/admin/books/badger-2026')
                ->assertSee('Badger')
                ->assertSee('No pages yet.');
        });

        $book = AuthoredBook::query()->sole();

        $this->assertSame('badger-2026', $book->book_uid);
        // A web-authored book gets its own one-book pack, slug = uid, and it
        // is a draft: creating a book publishes nothing (§10.3).
        $this->assertSame('badger-2026', $book->pack->slug);
        $this->assertSame(Pack::STATUS_DRAFT, $book->pack->status);
    }

    public function test_the_page_editor_shows_the_region_overlay(): void
    {
        $this->seedAuthoredBook();

        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->admin()->create())
                ->visit('/admin/books/coyote-2026')
                ->waitForText('Coyote at dusk')
                ->assertSee('mapped')
                ->click('a[href="/admin/books/coyote-2026/pages/0"]')
                ->waitForText('Region overlay')
                // The composited PNG really renders — it is a plain <img src>
                // onto a session-authenticated route. (`route()` hands back an
                // absolute URL, hence the suffix match.)
                ->waitFor('img[src$="/admin/books/coyote-2026/pages/0/preview"]')
                ->assertSee('Mapping tuning')
                ->assertSee('Masking image: no');
        });
    }

    public function test_a_page_that_mapped_and_still_fails_says_what_is_wrong(): void
    {
        // A giant region is a gap in the line art: the editor says so in words
        // an artist can act on, rather than hiding a broken page (§10.3).
        $this->seedAuthoredBook(case: 'giant-region');

        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->admin()->create())
                ->visit('/admin/books/coyote-2026/pages/0')
                ->waitForText('This page mapped, but it cannot be published yet.')
                ->assertSee('gap in the line art');
        });
    }

    public function test_publishing_a_book_is_one_button(): void
    {
        $this->seedAuthoredBook();

        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->admin()->create())
                ->visit('/admin/books/coyote-2026')
                ->waitForText('Coyote at dusk')
                ->clickAtXPath("//button[normalize-space()='Publish']")
                ->waitForText('Published v1.');
        });

        $version = PackVersion::query()->sole();

        $this->assertSame(1, $version->version);
        $this->assertNotNull($version->published_at);
        $this->assertSame(Pack::STATUS_PUBLISHED, Pack::query()->sole()->status);
        // Built through the one publish path, so the catalog rows exist too.
        $this->assertDatabaseHas('books', ['book_uid' => 'coyote-2026']);
    }

    public function test_a_book_with_a_failing_page_cannot_be_published(): void
    {
        $this->seedAuthoredBook(case: 'giant-region');

        $this->browse(function (Browser $browser): void {
            $browser->loginAs(User::factory()->admin()->create())
                ->visit('/admin/books/coyote-2026')
                ->waitForText('Coyote at dusk')
                // The reason is on the page beside the page it belongs to …
                ->assertSee('gap in the line art')
                // … and the button is disabled rather than absent, so the
                // operator can see that publishing is what is being refused.
                ->assertAttribute('[data-test="publish-book"]', 'disabled', 'true');
        });

        $this->assertDatabaseCount('pack_versions', 0);
    }
}
