<?php

namespace Tests\Feature\Admin;

use App\Models\AuthoredBook;
use App\Models\PackVersion;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\AdminsPacks;
use Tests\Concerns\AuthorsBooks;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * BL-38 — the artist's cover image.
 *
 * The rule the whole entry turns on is that the cover is **optional and its
 * absence is not a hole**: a book with no cover publishes the pack it always
 * published, with page one's display art named as the cover, so every pack
 * released before this exists is still exactly as valid as it was.
 *
 * So the interesting assertions here are the two boundaries — with a cover the
 * manifest names `books/<uid>/cover.png` and the file is really in the release;
 * without one it names `page_01.png`, verbatim as before.
 */
class BookCoverTest extends TestCase
{
    use AdminsPacks, AuthorsBooks, PublishesPacks, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakePackStorage();
    }

    private function bookWithPage(User $admin, string $uid = 'coyote-2026'): void
    {
        $this->actingAs($admin)->post('/admin/books', [
            'book_uid' => $uid,
            'title' => 'Coyote',
            'is_free' => true,
        ]);

        $this->fakeMapping();

        $this->actingAs($admin)->post("/admin/books/{$uid}/pages", [
            'display' => $this->pageUpload(),
        ]);
    }

    public function test_a_book_starts_with_no_cover(): void
    {
        $admin = User::factory()->admin()->create();
        $this->bookWithPage($admin);

        $this->actingAs($admin)
            ->get('/admin/books/coyote-2026')
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('admin/Book')
                ->where('book.has_cover', false)
                ->where('book.cover_url', null),
            );

        // A cover nobody uploaded is a 404 rather than an empty body: the
        // screen has to be able to tell "no cover" from "a cover that failed".
        $this->actingAs($admin)->get('/admin/books/coyote-2026/cover')->assertNotFound();
    }

    public function test_uploading_a_cover_stores_it_and_serves_it(): void
    {
        $admin = User::factory()->admin()->create();
        $this->bookWithPage($admin);

        $this->actingAs($admin)
            ->patch('/admin/books/coyote-2026', ['cover' => $this->pageUpload()])
            ->assertSessionHasNoErrors()
            ->assertRedirect('/admin/books/coyote-2026');

        $book = AuthoredBook::query()->sole();

        $this->assertNotNull($book->cover_asset_id);
        $this->assertSame('cover', $book->coverAsset?->kind);

        $response = $this->actingAs($admin)->get('/admin/books/coyote-2026/cover')->assertOk();

        $this->assertSame('image/png', $response->headers->get('Content-Type'));
        $this->assertNotFalse(@imagecreatefromstring($response->getContent()));
    }

    public function test_the_cover_can_be_removed_again(): void
    {
        $admin = User::factory()->admin()->create();
        $this->bookWithPage($admin);

        $this->actingAs($admin)->patch('/admin/books/coyote-2026', ['cover' => $this->pageUpload()]);
        $this->assertNotNull(AuthoredBook::query()->sole()->cover_asset_id);

        $this->actingAs($admin)
            ->patch('/admin/books/coyote-2026', ['remove_cover' => '1'])
            ->assertSessionHasNoErrors();

        $this->assertNull(AuthoredBook::query()->sole()->cover_asset_id);
    }

    public function test_a_retitle_leaves_the_cover_alone(): void
    {
        $admin = User::factory()->admin()->create();
        $this->bookWithPage($admin);

        $this->actingAs($admin)->patch('/admin/books/coyote-2026', ['cover' => $this->pageUpload()]);
        $coverId = AuthoredBook::query()->sole()->cover_asset_id;

        // A form submitting one field must never be read as clearing another.
        $this->actingAs($admin)->patch('/admin/books/coyote-2026', ['title' => 'Coyote at Dusk']);

        $book = AuthoredBook::query()->sole();

        $this->assertSame('Coyote at Dusk', $book->title);
        $this->assertSame($coverId, $book->cover_asset_id);
    }

    public function test_publishing_ships_the_cover_and_names_it_in_the_manifest(): void
    {
        $admin = User::factory()->admin()->create();
        $this->bookWithPage($admin);

        $this->actingAs($admin)->patch('/admin/books/coyote-2026', ['cover' => $this->pageUpload()]);

        $this->actingAs($admin)
            ->post('/admin/books/coyote-2026/publish')
            ->assertSessionMissing('book_errors');

        $manifest = PackVersion::query()->sole()->manifest;

        $this->assertSame('books/coyote-2026/cover.png', $manifest['cover']);
        $this->assertSame('books/coyote-2026/cover.png', $manifest['books'][0]['cover']);
        // Named in the file map, so it carries a digest like everything else
        // and a delta update can see it change (§7.2).
        $this->assertArrayHasKey('books/coyote-2026/cover.png', $manifest['files']);
        $this->assertSame(64, strlen($manifest['files']['books/coyote-2026/cover.png']['sha256']));

        // The catalog projection picked it up as the book's cover asset.
        $this->assertNotNull(
            PackVersion::query()->sole()->pack->books()->sole()->cover_asset_id,
        );
    }

    public function test_a_book_with_no_cover_still_publishes_page_one_as_the_cover(): void
    {
        $admin = User::factory()->admin()->create();
        $this->bookWithPage($admin);

        $this->actingAs($admin)->post('/admin/books/coyote-2026/publish');

        $manifest = PackVersion::query()->sole()->manifest;

        // Byte for byte the pre-BL-38 shape: old packs stay valid because
        // nothing about them moved.
        $this->assertSame('books/coyote-2026/page_01.png', $manifest['cover']);
        $this->assertSame('books/coyote-2026/page_01.png', $manifest['books'][0]['cover']);
        $this->assertArrayNotHasKey('books/coyote-2026/cover.png', $manifest['files']);
    }

    public function test_the_cover_rides_the_token_door_too(): void
    {
        $admin = User::factory()->admin()->create();
        $this->withToken($this->adminToken($admin));

        $book = $this->authorBook();

        $this->patch("/api/v1/admin/books/{$book->book_uid}", ['cover' => $this->pageUpload()])
            ->assertOk()
            ->assertJsonPath('book.has_cover', true);

        $this->get("/api/v1/admin/books/{$book->book_uid}/cover")
            ->assertOk()
            ->assertHeader('Content-Type', 'image/png');
    }
}
