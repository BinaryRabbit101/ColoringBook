<?php

namespace Tests\Feature\Api;

use App\Models\AuthoredBook;
use App\Models\AuthoredPage;
use App\Models\Book;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\Page;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\AdminsPacks;
use Tests\Concerns\AuthorsBooks;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * BL-24 — web authoring through the token door (§10.3, §11's web-authoring
 * table).
 *
 * The order of these tests is the flow, because the flow is the feature:
 * create a book → add pages → each page maps and is judged by §10.1 → publish
 * when, and only when, every page is clean.
 *
 * The mapping pipeline is faked (`AuthorsBooks::fakeMapping()`) — there is no
 * headless Godot in the gate, by construction. Everything either side of that
 * one process boundary is real: real uploads, real content-addressed assets,
 * real `PackValidation`, and a real `PublishPackDirectory` writing a real zip.
 */
class AdminBookAuthoringTest extends TestCase
{
    use AdminsPacks, AuthorsBooks, PublishesPacks, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakePackStorage();
    }

    // ------------------------------------------------------------- gating --

    public function test_a_game_token_cannot_author_books(): void
    {
        $this->withToken($this->issueDeviceToken())
            ->getJson('/api/v1/admin/books')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'MISSING_ABILITY');
    }

    public function test_authoring_needs_a_token_at_all(): void
    {
        $this->getJson('/api/v1/admin/books')
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'UNAUTHENTICATED');
    }

    // -------------------------------------------------------------- books --

    public function test_creating_a_book_creates_its_one_book_draft_pack(): void
    {
        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/books', [
                'book_uid' => 'coyote-2026',
                'title' => 'Coyote',
                'blurb' => 'One coyote.',
                'is_free' => true,
            ])
            ->assertCreated()
            ->assertJsonPath('book.book_uid', 'coyote-2026')
            // Slug = uid: packs stay the delivery unit, the operator thinks in
            // books (§10.3).
            ->assertJsonPath('book.pack_slug', 'coyote-2026')
            ->assertJsonPath('book.pack_status', Pack::STATUS_DRAFT)
            ->assertJsonPath('book.is_free', true)
            ->assertJsonPath('book.page_count', 0)
            // A book with no pages cannot publish, and says why.
            ->assertJsonPath('book.publishable', false);

        $this->assertSame(Pack::STATUS_DRAFT, Pack::query()->sole()->status);
    }

    public function test_a_book_uid_cannot_collide_with_a_published_book(): void
    {
        $this->publishFixturePack();

        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote'])
            ->assertUnprocessable()
            ->assertJsonPath('error.code', 'VALIDATION_FAILED')
            ->assertJsonStructure(['error' => ['details' => ['book_uid']]]);
    }

    public function test_a_book_uid_cannot_be_claimed_twice(): void
    {
        $token = $this->adminToken();

        $this->withToken($token)
            ->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote'])
            ->assertCreated();

        $this->withToken($token)
            ->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Another'])
            ->assertUnprocessable();
    }

    public function test_a_book_uid_must_be_slug_shaped(): void
    {
        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/books', ['book_uid' => 'Coyote 2026!', 'title' => 'Coyote'])
            ->assertUnprocessable();
    }

    public function test_retitling_a_book_renames_its_pack_too(): void
    {
        $this->withToken($this->adminToken());
        $book = $this->authorBook();

        $this->patchJson('/api/v1/admin/books/coyote-2026', ['title' => 'Coyote at dusk'])
            ->assertOk()
            ->assertJsonPath('book.title', 'Coyote at dusk');

        $this->assertSame('Coyote at dusk', $book->pack->refresh()->title);
    }

    // -------------------------------------------------------------- pages --

    public function test_adding_a_page_maps_it_and_records_the_verdict(): void
    {
        $this->withToken($this->adminToken());

        $this->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote'])
            ->assertCreated();

        $runner = $this->fakeMapping();

        $this->post('/api/v1/admin/books/coyote-2026/pages', [
            'display' => $this->pageUpload(),
            'title' => 'Coyote at dusk',
        ])
            ->assertCreated()
            ->assertJsonPath('page.page_index', 0)
            ->assertJsonPath('page.title', 'Coyote at dusk')
            ->assertJsonPath('page.mapping_status', AuthoredPage::STATUS_MAPPED)
            ->assertJsonPath('page.region_count', 4)
            ->assertJsonPath('page.image_size', [16, 16])
            ->assertJsonPath('page.validation_errors', [])
            ->assertJsonPath('page.publishable', true)
            ->assertJsonPath('page.has_mask', false);

        // BL-9: with no mask, the display image is its own mapping source.
        $this->assertCount(1, $runner->requests);
        $this->assertNull($runner->requests[0]->maskPath);
        $this->assertSame($runner->requests[0]->displayPath, $runner->requests[0]->sourcePath());
    }

    public function test_a_masked_page_maps_from_the_mask_and_ships_the_resample(): void
    {
        $this->withToken($this->adminToken());

        $this->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote'])
            ->assertCreated();

        $runner = $this->fakeMapping();

        $this->post('/api/v1/admin/books/coyote-2026/pages', [
            'display' => $this->pageUpload(),
            'mask' => $this->pageUpload('valid', 'page_01.png', 'mask.png'),
        ])
            ->assertCreated()
            ->assertJsonPath('page.has_mask', true)
            // BL-12: the pack ships the pipeline's display-resolution resample,
            // never the artist's print-size original.
            ->assertJsonPath('page.shipped_mask.kind', 'mask');

        $this->assertNotNull($runner->requests[0]->maskPath);
        $this->assertSame($runner->requests[0]->maskPath, $runner->requests[0]->sourcePath());
        // Never the path the pipeline writes its own output to.
        $this->assertNotSame($runner->requests[0]->maskArtifactPath(), $runner->requests[0]->maskPath);
    }

    public function test_a_page_needs_its_detail_image(): void
    {
        $this->withToken($this->adminToken());
        $this->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);

        $this->postJson('/api/v1/admin/books/coyote-2026/pages', ['title' => 'No art'])
            ->assertUnprocessable()
            ->assertJsonPath('error.code', 'VALIDATION_FAILED');
    }

    public function test_pages_are_appended_and_reordering_renumbers_the_book(): void
    {
        $this->withToken($this->adminToken());
        $book = $this->authorBook(pages: 3);

        $this->assertSame([0, 1, 2], array_map(
            fn (AuthoredPage $page): int => $page->page_index,
            $this->pagesOf($book),
        ));

        // Move the last page to the front.
        $this->patchJson('/api/v1/admin/books/coyote-2026/pages/2', ['page_index' => 0])
            ->assertOk()
            ->assertJsonPath('page.page_index', 0);

        $titles = array_map(fn (AuthoredPage $page): ?string => $page->title, $this->pagesOf($book));

        $this->assertSame(['Page 3', 'Page 1', 'Page 2'], $titles);
    }

    public function test_removing_a_page_closes_the_gap(): void
    {
        $this->withToken($this->adminToken());
        $book = $this->authorBook(pages: 3);

        $this->deleteJson('/api/v1/admin/books/coyote-2026/pages/0')->assertNoContent();

        $pages = $this->pagesOf($book);

        $this->assertSame([0, 1], array_map(fn (AuthoredPage $page): int => $page->page_index, $pages));
        $this->assertSame(['Page 2', 'Page 3'], array_map(fn (AuthoredPage $page): ?string => $page->title, $pages));
    }

    public function test_replacing_the_detail_image_re_queues_the_mapping(): void
    {
        $this->withToken($this->adminToken());
        $this->authorBook();

        $runner = $this->fakeMapping();

        $this->patch('/api/v1/admin/books/coyote-2026/pages/0', [
            'display' => $this->pageUpload('giant-region'),
        ])
            ->assertOk()
            ->assertJsonPath('page.mapping_status', AuthoredPage::STATUS_MAPPED);

        $this->assertCount(1, $runner->requests);
    }

    public function test_a_retitle_does_not_re_map(): void
    {
        $this->withToken($this->adminToken());
        $this->authorBook();

        $runner = $this->fakeMapping();

        $this->patchJson('/api/v1/admin/books/coyote-2026/pages/0', ['title' => 'Renamed'])
            ->assertOk()
            ->assertJsonPath('page.title', 'Renamed')
            ->assertJsonPath('page.mapping_status', AuthoredPage::STATUS_MAPPED);

        $this->assertSame([], $runner->requests);
    }

    public function test_per_page_tuning_reaches_the_pipeline(): void
    {
        $this->withToken($this->adminToken());
        $this->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);

        $runner = $this->fakeMapping();

        $this->post('/api/v1/admin/books/coyote-2026/pages', [
            'display' => $this->pageUpload(),
            'tuning' => ['dilate' => 3, 'min_area' => 128],
        ])->assertCreated();

        // The defaults are still there underneath the two overrides.
        $tuning = $runner->requests[0]->tuning;

        $this->assertSame(3, $tuning['dilate']);
        $this->assertSame(128, $tuning['min_area']);
        $this->assertSame(config('coloringbook.authoring.tuning.rdp'), $tuning['rdp']);
    }

    public function test_a_tuning_knob_outside_the_pipeline_range_is_refused(): void
    {
        $this->withToken($this->adminToken());
        $this->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);
        $this->fakeMapping();

        $this->post('/api/v1/admin/books/coyote-2026/pages', [
            'display' => $this->pageUpload(),
            'tuning' => ['dilate' => -3],
        ])->assertUnprocessable();
    }

    // --------------------------------------------------- failure reporting --

    public function test_a_giant_region_is_reported_in_plain_language(): void
    {
        $this->withToken($this->adminToken());
        $this->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);

        $this->fakeMapping('giant-region');

        $response = $this->post('/api/v1/admin/books/coyote-2026/pages', [
            'display' => $this->pageUpload('giant-region'),
        ])->assertCreated();

        // It mapped: the pipeline ran and produced artifacts.
        $response->assertJsonPath('page.mapping_status', AuthoredPage::STATUS_MAPPED);
        // It is still not publishable, and the reason is about the drawing.
        $response->assertJsonPath('page.publishable', false);

        $errors = $response->json('page.validation_errors');

        $this->assertIsArray($errors);
        $this->assertNotEmpty($errors);
        $this->assertStringContainsString('gap in the line art', implode(' ', $errors));
    }

    public function test_a_pipeline_refusal_lands_on_the_page_rather_than_throwing(): void
    {
        $this->withToken($this->adminToken());
        $this->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);

        $this->fakeMapping(failWith: 'region 1 covers 97.0% of the paintable pixels');

        $this->post('/api/v1/admin/books/coyote-2026/pages', ['display' => $this->pageUpload()])
            ->assertCreated()
            ->assertJsonPath('page.mapping_status', AuthoredPage::STATUS_FAILED)
            ->assertJsonPath('page.publishable', false)
            ->assertJsonPath('page.mapping_error', 'region 1 covers 97.0% of the paintable pixels');
    }

    public function test_the_status_route_is_what_the_editor_polls(): void
    {
        $this->withToken($this->adminToken());
        $this->authorBook();

        $this->getJson('/api/v1/admin/books/coyote-2026/pages/0/status')
            ->assertOk()
            ->assertJsonPath('page.mapping_status', AuthoredPage::STATUS_MAPPED)
            ->assertJsonPath('page.publishable', true)
            ->assertJsonStructure(['page' => ['preview_url', 'status_url', 'effective_tuning']]);
    }

    public function test_the_region_overlay_preview_is_a_png(): void
    {
        $this->withToken($this->adminToken());
        $this->authorBook();

        $response = $this->get('/api/v1/admin/books/coyote-2026/pages/0/preview')->assertOk();

        $this->assertSame('image/png', $response->headers->get('Content-Type'));
        $this->assertNotFalse(@imagecreatefromstring($response->getContent()));
    }

    public function test_an_unmapped_page_has_no_preview_to_show(): void
    {
        $this->withToken($this->adminToken());
        $this->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);
        $this->fakeMapping(failWith: 'nope');
        $this->post('/api/v1/admin/books/coyote-2026/pages', ['display' => $this->pageUpload()]);

        $this->getJson('/api/v1/admin/books/coyote-2026/pages/0/preview')
            ->assertNotFound()
            ->assertJsonPath('error.code', 'PAGE_NOT_MAPPED');
    }

    // ------------------------------------------------------------ publish --

    public function test_publishing_refuses_while_a_page_is_failing(): void
    {
        $this->withToken($this->adminToken());
        $this->authorBook();

        $this->fakeMapping('giant-region');
        $this->post('/api/v1/admin/books/coyote-2026/pages', ['display' => $this->pageUpload('giant-region')]);

        $this->postJson('/api/v1/admin/books/coyote-2026/publish')
            ->assertUnprocessable()
            ->assertJsonPath('error.code', 'BOOK_NOT_PUBLISHABLE');

        $this->assertSame(0, PackVersion::query()->count());
    }

    public function test_publishing_an_empty_book_refuses(): void
    {
        $this->withToken($this->adminToken());
        $this->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);

        $this->postJson('/api/v1/admin/books/coyote-2026/publish')
            ->assertUnprocessable()
            ->assertJsonPath('error.code', 'BOOK_NOT_PUBLISHABLE');
    }

    public function test_publishing_builds_a_pack_version_through_the_one_publish_path(): void
    {
        $this->withToken($this->adminToken());
        $this->authorBook(pages: 2);

        $this->postJson('/api/v1/admin/books/coyote-2026/publish')
            ->assertCreated()
            ->assertJsonPath('pack_slug', 'coyote-2026')
            ->assertJsonPath('version', 1)
            ->assertJsonPath('status', 'published');

        /** @var PackVersion $version */
        $version = PackVersion::query()->sole();

        $this->assertNotNull($version->published_at);
        $this->assertSame(Pack::STATUS_PUBLISHED, Pack::query()->sole()->status);

        // The catalog rows are rebuilt from the manifest, exactly as they are
        // for a zip upload — no second import path.
        $this->assertSame('coyote-2026', Book::query()->sole()->book_uid);
        $this->assertSame(2, Page::query()->count());

        // §7.2 layout, in the shipped manifest.
        $manifest = $version->manifest;
        $this->assertArrayHasKey('books/coyote-2026/page_01.png', $manifest['files']);
        $this->assertArrayHasKey('books/coyote-2026/page_01_idmap.png', $manifest['files']);
        $this->assertArrayHasKey('books/coyote-2026/page_01_regions.json', $manifest['files']);
        $this->assertArrayHasKey('books/coyote-2026/page_02.png', $manifest['files']);
        // Synthesised by the publisher, so the installed tree is
        // self-describing.
        $this->assertArrayHasKey('books/coyote-2026/book.json', $manifest['files']);

        // And the pack really is downloadable now.
        $this->getJson('/api/v1/packs')
            ->assertOk()
            ->assertJsonPath('packs.0.slug', 'coyote-2026')
            ->assertJsonPath('packs.0.is_free', true);
    }

    public function test_a_masked_page_ships_its_mask_file(): void
    {
        $this->withToken($this->adminToken());
        $this->postJson('/api/v1/admin/books', ['book_uid' => 'coyote-2026', 'title' => 'Coyote']);
        $this->fakeMapping();

        $this->post('/api/v1/admin/books/coyote-2026/pages', [
            'display' => $this->pageUpload(),
            'mask' => $this->pageUpload('valid', 'page_01.png', 'mask.png'),
        ])->assertCreated();

        $this->postJson('/api/v1/admin/books/coyote-2026/publish')->assertCreated();

        $manifest = PackVersion::query()->sole()->manifest;

        $this->assertArrayHasKey('books/coyote-2026/page_01_mask.png', $manifest['files']);
        $this->assertSame('books/coyote-2026/page_01_mask.png', $manifest['books'][0]['pages'][0]['mask']);
    }

    public function test_an_unmasked_page_ships_no_mask_file(): void
    {
        $this->withToken($this->adminToken());
        $this->authorBook();

        $this->postJson('/api/v1/admin/books/coyote-2026/publish')->assertCreated();

        $manifest = PackVersion::query()->sole()->manifest;

        $this->assertArrayNotHasKey('books/coyote-2026/page_01_mask.png', $manifest['files']);
        $this->assertArrayNotHasKey('mask', $manifest['books'][0]['pages'][0]);
    }

    public function test_publishing_again_is_a_new_immutable_version(): void
    {
        $this->withToken($this->adminToken());
        $this->authorBook();

        $this->postJson('/api/v1/admin/books/coyote-2026/publish')->assertCreated();

        $this->fakeMapping();
        $this->post('/api/v1/admin/books/coyote-2026/pages', ['display' => $this->pageUpload()])
            ->assertCreated();

        $this->postJson('/api/v1/admin/books/coyote-2026/publish')
            ->assertCreated()
            ->assertJsonPath('version', 2);

        $this->assertSame([1, 2], PackVersion::query()->orderBy('version')->pluck('version')->all());
        $this->assertSame(2, Page::query()->count());
    }

    // ------------------------------------------------------------- delete --

    public function test_deleting_a_never_published_book_removes_it_outright(): void
    {
        $this->withToken($this->adminToken());
        $this->authorBook();

        $this->deleteJson('/api/v1/admin/books/coyote-2026')
            ->assertOk()
            ->assertJsonPath('outcome', 'deleted');

        $this->assertSame(0, AuthoredBook::query()->count());
        $this->assertSame(0, AuthoredPage::query()->count());
        $this->assertSame(0, Pack::query()->count());
    }

    public function test_deleting_a_published_book_retires_its_pack(): void
    {
        $this->withToken($this->adminToken());
        $this->authorBook();
        $this->postJson('/api/v1/admin/books/coyote-2026/publish')->assertCreated();

        $this->deleteJson('/api/v1/admin/books/coyote-2026')
            ->assertOk()
            ->assertJsonPath('outcome', 'retired');

        // The workspace is gone; the pack and its bytes are not (§7.3).
        $this->assertSame(0, AuthoredBook::query()->count());
        $this->assertSame(Pack::STATUS_RETIRED, Pack::query()->sole()->status);
        $this->assertSame(1, PackVersion::query()->count());
    }
}
