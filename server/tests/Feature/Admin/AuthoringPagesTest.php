<?php

namespace Tests\Feature\Admin;

use App\Models\AuthoredBook;
use App\Models\AuthoredPage;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\AdminsPacks;
use Tests\Concerns\AuthorsBooks;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * BL-24 — web authoring in the browser (§10.3).
 *
 * The Inertia half. Same actions, same FormRequests, same publish path as the
 * token door; what these tests are actually for is the *differences*: a 404
 * rather than a 403 for a parent who guesses the URL, and a refused publish
 * that bounces back to the book with the whole list of reasons instead of a
 * 422 nobody in a browser would ever read.
 */
class AuthoringPagesTest extends TestCase
{
    use AdminsPacks, AuthorsBooks, PublishesPacks, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakePackStorage();
    }

    public function test_an_ordinary_parent_gets_a_404(): void
    {
        $user = User::factory()->create();

        $this->actingAs($user)->get('/admin/books')->assertNotFound();
        $this->actingAs($user)
            ->post('/admin/books', ['book_uid' => 'sneaky-2026', 'title' => 'Sneaky'])
            ->assertNotFound();

        $this->assertSame(0, AuthoredBook::query()->count());
    }

    public function test_a_signed_out_visitor_is_sent_to_login(): void
    {
        $this->get('/admin/books')->assertRedirect(route('login'));
    }

    public function test_the_book_list_renders(): void
    {
        AuthoredBook::factory()->create(['book_uid' => 'coyote-2026', 'title' => 'Coyote']);

        $this->actingAs(User::factory()->admin()->create())
            ->get('/admin/books')
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('admin/Books')
                ->has('books', 1)
                ->where('books.0.book_uid', 'coyote-2026')
                ->where('books.0.pack_status', Pack::STATUS_DRAFT),
            );
    }

    public function test_an_admin_creates_a_book_from_the_form(): void
    {
        $this->actingAs(User::factory()->admin()->create())
            ->post('/admin/books', [
                'book_uid' => 'coyote-2026',
                'title' => 'Coyote',
                'is_free' => true,
            ])
            ->assertSessionHasNoErrors()
            ->assertRedirect('/admin/books/coyote-2026');

        $this->assertSame('coyote-2026', Pack::query()->sole()->slug);
        $this->assertTrue(Pack::query()->sole()->is_free);
    }

    public function test_adding_a_page_lands_on_the_editor_with_its_verdict(): void
    {
        $admin = User::factory()->admin()->create();
        $this->actingAs($admin)->post('/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);

        $this->fakeMapping();

        $this->actingAs($admin)
            ->post('/admin/books/coyote-2026/pages', [
                'display' => $this->pageUpload(),
                'title' => 'Coyote at dusk',
            ])
            ->assertSessionHasNoErrors()
            ->assertRedirect('/admin/books/coyote-2026/pages/0');

        $this->actingAs($admin)
            ->get('/admin/books/coyote-2026/pages/0')
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('admin/AuthoredPage')
                ->where('page.mapping_status', AuthoredPage::STATUS_MAPPED)
                ->where('page.publishable', true)
                ->where('page.validation_errors', [])
                ->has('page.preview_url'),
            );
    }

    public function test_the_page_form_refuses_without_a_detail_image(): void
    {
        $admin = User::factory()->admin()->create();
        $this->actingAs($admin)->post('/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);

        $this->actingAs($admin)
            ->from('/admin/books/coyote-2026')
            ->post('/admin/books/coyote-2026/pages', ['title' => 'No art'])
            ->assertSessionHasErrors('display');
    }

    public function test_the_editor_shows_a_giant_region_in_plain_language(): void
    {
        $admin = User::factory()->admin()->create();
        $this->actingAs($admin)->post('/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);

        $this->fakeMapping('giant-region');

        $this->actingAs($admin)->post('/admin/books/coyote-2026/pages', [
            'display' => $this->pageUpload('giant-region'),
        ]);

        $this->actingAs($admin)
            ->get('/admin/books/coyote-2026/pages/0')
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('admin/AuthoredPage')
                ->where('page.publishable', false)
                ->where(
                    'page.validation_errors',
                    fn ($errors): bool => str_contains(implode(' ', (array) collect($errors)->all()), 'gap in the line art'),
                ),
            );
    }

    public function test_the_preview_route_serves_a_png_to_an_img_tag(): void
    {
        $admin = User::factory()->admin()->create();
        $this->actingAs($admin)->post('/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);
        $this->fakeMapping();
        $this->actingAs($admin)->post('/admin/books/coyote-2026/pages', ['display' => $this->pageUpload()]);

        $response = $this->actingAs($admin)
            ->get('/admin/books/coyote-2026/pages/0/preview')
            ->assertOk();

        $this->assertSame('image/png', $response->headers->get('Content-Type'));
        $this->assertNotFalse(@imagecreatefromstring($response->getContent()));
    }

    public function test_the_status_route_answers_json_for_polling(): void
    {
        $admin = User::factory()->admin()->create();
        $this->actingAs($admin)->post('/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);
        $this->fakeMapping();
        $this->actingAs($admin)->post('/admin/books/coyote-2026/pages', ['display' => $this->pageUpload()]);

        $this->actingAs($admin)
            ->getJson('/admin/books/coyote-2026/pages/0/status')
            ->assertOk()
            ->assertJsonPath('page.mapping_status', AuthoredPage::STATUS_MAPPED);
    }

    public function test_a_refused_publish_bounces_with_the_whole_list(): void
    {
        $admin = User::factory()->admin()->create();
        $this->actingAs($admin)->post('/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);

        $this->fakeMapping('giant-region');
        $this->actingAs($admin)->post('/admin/books/coyote-2026/pages', [
            'display' => $this->pageUpload('giant-region'),
        ]);

        $this->actingAs($admin)
            ->post('/admin/books/coyote-2026/publish')
            ->assertRedirect('/admin/books/coyote-2026')
            ->assertSessionHas('book_errors');

        $this->assertSame(0, PackVersion::query()->count());

        $this->actingAs($admin)
            ->get('/admin/books/coyote-2026')
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('admin/Book')
                ->has('publishErrors', 1),
            );
    }

    public function test_publishing_from_the_browser_ships_a_version(): void
    {
        $admin = User::factory()->admin()->create();
        $this->actingAs($admin)->post('/admin/books', [
            'book_uid' => 'coyote-2026',
            'title' => 'Coyote',
            'is_free' => true,
        ]);

        $this->fakeMapping();
        $this->actingAs($admin)->post('/admin/books/coyote-2026/pages', ['display' => $this->pageUpload()]);

        $this->actingAs($admin)
            ->post('/admin/books/coyote-2026/publish')
            ->assertRedirect('/admin/books/coyote-2026');

        $this->assertNotNull(PackVersion::query()->sole()->published_at);
        $this->assertSame(Pack::STATUS_PUBLISHED, Pack::query()->sole()->status);
    }

    public function test_reordering_from_the_book_page_follows_the_page(): void
    {
        $admin = User::factory()->admin()->create();
        $this->actingAs($admin)->post('/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);

        $this->fakeMapping();

        foreach (['One', 'Two'] as $title) {
            $this->actingAs($admin)->post('/admin/books/coyote-2026/pages', [
                'display' => $this->pageUpload(),
                'title' => $title,
            ]);
        }

        // The redirect has to follow the page to wherever it landed.
        $this->actingAs($admin)
            ->patch('/admin/books/coyote-2026/pages/1', ['page_index' => 0])
            ->assertRedirect('/admin/books/coyote-2026/pages/0');

        $this->assertSame(
            ['Two', 'One'],
            AuthoredPage::query()->orderBy('page_index')->pluck('title')->all(),
        );
    }

    public function test_removing_a_published_book_retires_it_rather_than_deleting(): void
    {
        $admin = User::factory()->admin()->create();
        $this->actingAs($admin)->post('/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);
        $this->fakeMapping();
        $this->actingAs($admin)->post('/admin/books/coyote-2026/pages', ['display' => $this->pageUpload()]);
        $this->actingAs($admin)->post('/admin/books/coyote-2026/publish');

        $this->actingAs($admin)
            ->delete('/admin/books/coyote-2026')
            ->assertRedirect('/admin/books');

        $this->assertSame(Pack::STATUS_RETIRED, Pack::query()->sole()->status);
        $this->assertSame(0, AuthoredBook::query()->count());
    }
}
