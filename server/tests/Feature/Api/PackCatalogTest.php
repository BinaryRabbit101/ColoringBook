<?php

namespace Tests\Feature\Api;

use App\Models\Device;
use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\PackVersion;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * `GET /api/v1/packs` and `GET /api/v1/packs/{slug}` — the shop window
 * (DLC_SERVER.md §11 "Catalog & DLC").
 */
class PackCatalogTest extends TestCase
{
    use PublishesPacks, RefreshDatabase;

    public function test_it_lists_published_packs_to_a_signed_out_client(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack();

        $response = $this->getJson('/api/v1/packs');

        $response->assertOk()
            ->assertJsonCount(1, 'packs')
            ->assertJsonPath('packs.0.slug', 'forest-friends')
            ->assertJsonPath('packs.0.title', 'Forest Friends')
            ->assertJsonPath('packs.0.latest_version', 1)
            ->assertJsonPath('packs.0.min_client_version', '0.7.0')
            ->assertJsonPath('packs.0.book_count', 2)
            ->assertJsonPath('packs.0.page_count', 3)
            ->assertJsonPath('packs.0.owned', false);
    }

    public function test_it_hides_draft_and_retired_packs(): void
    {
        Pack::factory()->draft()->create(['slug' => 'not-ready']);
        Pack::factory()->retired()->create(['slug' => 'gone']);
        $published = Pack::factory()->create(['slug' => 'here']);
        PackVersion::factory()->for($published, 'pack')->create();

        $response = $this->getJson('/api/v1/packs');

        $response->assertOk()->assertJsonCount(1, 'packs');
        $this->assertSame('here', $response->json('packs.0.slug'));

        $this->getJson('/api/v1/packs/not-ready')
            ->assertNotFound()
            ->assertJsonPath('error.code', 'NOT_FOUND');

        // Retired is a delisting, not a deletion — but the shop still won't
        // show it (§7.3).
        $this->getJson('/api/v1/packs/gone')->assertNotFound();
    }

    public function test_a_published_pack_with_no_published_version_is_not_a_product(): void
    {
        $pack = Pack::factory()->create(['slug' => 'empty-shelf']);
        PackVersion::factory()->for($pack, 'pack')->draft()->create();

        $this->getJson('/api/v1/packs')->assertOk()->assertJsonCount(0, 'packs');
    }

    public function test_client_version_filtering_hides_a_release_the_build_cannot_run(): void
    {
        $pack = Pack::factory()->create(['slug' => 'forest-friends']);
        PackVersion::factory()->for($pack, 'pack')->version(1)->requiresClient('0.7.0')->create();
        PackVersion::factory()->for($pack, 'pack')->version(2)->requiresClient('0.9.0')->create();

        // A current build gets the newest release.
        $this->getJson('/api/v1/packs?client_version=0.9.0')
            ->assertOk()
            ->assertJsonPath('packs.0.latest_version', 2);

        // An older build is offered the newest release it can actually run,
        // rather than being offered v2 and then crashing on it (§7.3).
        $this->getJson('/api/v1/packs?client_version=0.8.0')
            ->assertOk()
            ->assertJsonPath('packs.0.latest_version', 1);

        // No filter at all means "show me everything".
        $this->getJson('/api/v1/packs')
            ->assertOk()
            ->assertJsonPath('packs.0.latest_version', 2);
    }

    public function test_client_version_filtering_compares_numerically_not_lexically(): void
    {
        $pack = Pack::factory()->create(['slug' => 'forest-friends']);
        PackVersion::factory()->for($pack, 'pack')->version(1)->requiresClient('0.9.0')->create();

        // Lexically "0.10.0" < "0.9.0"; by version_compare it is newer.
        $this->getJson('/api/v1/packs?client_version=0.10.0')
            ->assertOk()
            ->assertJsonCount(1, 'packs');
    }

    public function test_a_pack_no_release_supports_drops_out_of_the_listing(): void
    {
        $pack = Pack::factory()->create(['slug' => 'future-pack']);
        PackVersion::factory()->for($pack, 'pack')->requiresClient('9.0.0')->create();

        $this->getJson('/api/v1/packs?client_version=0.7.0')
            ->assertOk()
            ->assertJsonCount(0, 'packs');
    }

    public function test_it_rejects_a_client_version_that_is_not_a_version(): void
    {
        $this->getJson('/api/v1/packs?client_version=not-a-version')
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED');
    }

    public function test_the_owned_flag_reflects_a_live_entitlement(): void
    {
        $this->fakePackStorage();
        $version = $this->publishFixturePack();
        $pack = $version->pack;

        $device = Device::factory()->create();
        Entitlement::factory()->for($device)->for($pack)->create();

        $other = Device::factory()->create();

        $this->withToken($this->issueDeviceToken($device))
            ->getJson('/api/v1/packs')
            ->assertOk()
            ->assertJsonPath('packs.0.owned', true);

        $this->forgetResolvedGuards()
            ->withToken($this->issueDeviceToken($other))
            ->getJson('/api/v1/packs')
            ->assertOk()
            ->assertJsonPath('packs.0.owned', false);
    }

    public function test_a_revoked_entitlement_is_not_owned(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;

        $device = Device::factory()->create();
        Entitlement::factory()->for($device)->for($pack)->revoked()->create();

        $this->withToken($this->issueDeviceToken($device))
            ->getJson('/api/v1/packs')
            ->assertOk()
            ->assertJsonPath('packs.0.owned', false);
    }

    public function test_a_free_pack_is_not_owned_until_it_is_claimed(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack(free: true);

        $device = Device::factory()->create();

        $this->withToken($this->issueDeviceToken($device))
            ->getJson('/api/v1/packs')
            ->assertOk()
            ->assertJsonPath('packs.0.is_free', true)
            ->assertJsonPath('packs.0.owned', false);
    }

    public function test_a_bad_bearer_token_still_gets_the_public_catalog(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack();

        // Browsing the shop is never a failure state for a child, so a stale
        // token degrades to anonymous rather than 401ing.
        $this->withToken('not-a-real-token')
            ->getJson('/api/v1/packs')
            ->assertOk()
            ->assertJsonPath('packs.0.owned', false);
    }

    public function test_the_detail_route_lists_the_books_in_the_pack(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack();

        $response = $this->getJson('/api/v1/packs/forest-friends');

        $response->assertOk()
            ->assertJsonPath('pack.slug', 'forest-friends')
            ->assertJsonPath('pack.cover', 'cover.png')
            ->assertJsonPath('pack.latest_version', 1)
            ->assertJsonCount(2, 'pack.books')
            ->assertJsonPath('pack.books.0.book_uid', 'coyote-2026')
            ->assertJsonPath('pack.books.0.page_count', 2)
            ->assertJsonPath('pack.books.1.book_uid', 'badger-2026')
            ->assertJsonPath('pack.books.1.page_count', 1);

        $this->assertSame(
            $response->json('pack.bytes'),
            $this->publishedVersionBytes('forest-friends'),
        );
    }

    public function test_it_never_exposes_internal_keys_or_storage_paths(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack();

        $pack = $this->getJson('/api/v1/packs/forest-friends')->json('pack');

        foreach (['id', 'ulid', 'status', 'cover_path', 'archive_path'] as $leak) {
            $this->assertArrayNotHasKey($leak, $pack);
        }
    }

    private function publishedVersionBytes(string $slug): int
    {
        /** @var Pack $pack */
        $pack = Pack::query()->where('slug', $slug)->sole();

        return (int) $pack->versions()->published()->firstOrFail()->archive_bytes;
    }
}
