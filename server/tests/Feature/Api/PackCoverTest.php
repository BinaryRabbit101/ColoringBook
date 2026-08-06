<?php

namespace Tests\Feature\Api;

use App\Models\Pack;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * `GET /packs/{slug}/cover` — the gap WP3 flagged: a shop that cannot render a
 * cover for a pack nobody owns has nothing to sell.
 *
 * Public and unsigned, unlike every other pack byte, and listable packs only.
 */
class PackCoverTest extends TestCase
{
    use PublishesPacks, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakePackStorage();
    }

    public function test_anyone_may_fetch_a_published_packs_cover(): void
    {
        $version = $this->publishFixturePack();

        $response = $this->get('/api/v1/packs/forest-friends/cover')->assertOk();

        $this->assertSame('image/png', $response->headers->get('Content-Type'));
        $this->assertNotFalse(@imagecreatefromstring($response->getContent()));

        // Content-addressed bytes under an immutable version: cacheable.
        $this->assertStringContainsString('public', (string) $response->headers->get('Cache-Control'));
        $this->assertSame(
            '"'.$version->files()['cover.png']['sha256'].'"',
            $response->headers->get('ETag'),
        );
    }

    public function test_the_catalog_advertises_the_cover_url(): void
    {
        $this->publishFixturePack();

        $this->getJson('/api/v1/packs')
            ->assertOk()
            ->assertJsonPath('packs.0.cover', 'cover.png')
            ->assertJsonPath('packs.0.cover_url', route('api.v1.packs.cover', ['slug' => 'forest-friends']));
    }

    public function test_an_unlisted_pack_has_no_public_cover(): void
    {
        $this->publishFixturePack();

        Pack::query()->sole()->update(['status' => Pack::STATUS_RETIRED]);

        // Delisted means invisible to the shop — its owners still download it
        // through the entitled routes, which is where retired packs live on.
        $this->getJson('/api/v1/packs/forest-friends/cover')->assertNotFound();
    }

    public function test_a_pack_with_no_cover_is_a_clean_404(): void
    {
        $this->publishFixturePack();

        Pack::query()->sole()->update(['cover_path' => null]);

        $this->getJson('/api/v1/packs/forest-friends/cover')
            ->assertNotFound()
            ->assertJsonPath('error.code', 'FILE_NOT_FOUND');
    }
}
