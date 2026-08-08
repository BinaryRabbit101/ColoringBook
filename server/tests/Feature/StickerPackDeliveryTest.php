<?php

namespace Tests\Feature;

use App\Actions\Packs\PublishPackDirectory;
use App\Models\Asset;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\Sticker;
use App\Models\StickerSet;
use App\Models\User;
use App\Services\PackManifest;
use App\Services\PackManifestValidator;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\AuthorsStickerSets;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * BL-37 — a sticker pack goes through the *existing* machinery unchanged.
 *
 * That is the whole claim of the server half, so it is what these tests are
 * about: `pack:publish`'s action imports it, the catalog lists it, an entitled
 * device downloads it, and a delta update diffs it — none of which needed a
 * sticker-shaped code path, because none of them ever cared what the files are.
 */
class StickerPackDeliveryTest extends TestCase
{
    use AuthorsStickerSets, PublishesPacks, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakePackStorage();
    }

    private function publishStickerPack(?bool $free = true): PackVersion
    {
        return app(PublishPackDirectory::class)
            ->handle($this->stickerPackFixturePath(), null, $free)
            ->version;
    }

    public function test_the_publisher_imports_a_sticker_pack_directory(): void
    {
        $version = $this->publishStickerPack();

        $pack = $version->pack;

        $this->assertSame('sticker-sheet', $pack->slug);
        $this->assertSame(Pack::KIND_STICKER_SET, $pack->kind);
        $this->assertSame(Pack::STATUS_PUBLISHED, $pack->status);
        $this->assertTrue($pack->is_free);

        // The catalog projection, exactly as books get one.
        $this->assertSame(1, StickerSet::query()->count());
        $this->assertSame(3, Sticker::query()->count());

        /** @var StickerSet $set */
        $set = StickerSet::query()->sole();

        $this->assertSame('sheet-stickers-2026', $set->set_uid);
        $this->assertSame(20, $set->sort_order);
        $this->assertSame(['star', 'heart', 'moon'], $set->stickers->pluck('sticker_id')->all());
        $this->assertSame([64, 64], [$set->stickers[0]->image_w, $set->stickers[0]->image_h]);

        // One role for a sticker's bytes, and the cover is the same blob wearing
        // a second `assets.kind` hat.
        $this->assertSame(3, Asset::query()->where('kind', 'sticker')->count());
        $this->assertSame(1, Asset::query()->where('kind', 'cover')->count());
    }

    public function test_the_published_manifest_says_what_it_carries(): void
    {
        $version = $this->publishStickerPack();

        $this->assertSame(Pack::KIND_STICKER_SET, $version->manifest['kind']);
        $this->assertArrayHasKey('sticker_sets', $version->manifest);
        // The fixture ships its own sticker_set.json, so the publisher leaves
        // it alone rather than synthesising a second one.
        $this->assertArrayHasKey(
            'stickers/sheet-stickers-2026/sticker_set.json',
            $version->manifest['files'],
        );
    }

    public function test_a_book_manifest_with_no_kind_still_publishes_as_a_book(): void
    {
        // Back-compat, and the reason the column defaults: every manifest ever
        // written before BL-37 has no `kind` key and every one of them is books.
        $version = $this->publishFixturePack();

        $this->assertSame(Pack::KIND_BOOK, $version->pack->kind);
        $this->assertSame(Pack::KIND_BOOK, $version->manifest['kind']);
    }

    public function test_the_shop_shows_the_kind_on_the_card(): void
    {
        $this->publishStickerPack();
        $this->publishFixturePack();

        $response = $this->getJson('/api/v1/packs')->assertOk();

        /** @var array<int, array<string, mixed>> $packs */
        $packs = $response->json('packs');
        $byKind = collect($packs)->keyBy('slug');

        $this->assertSame(Pack::KIND_STICKER_SET, $byKind['sticker-sheet']['kind']);
        $this->assertSame(3, $byKind['sticker-sheet']['sticker_count']);
        $this->assertSame(1, $byKind['sticker-sheet']['sticker_set_count']);
        $this->assertSame(0, $byKind['sticker-sheet']['book_count']);

        $this->assertSame(Pack::KIND_BOOK, $byKind['forest-friends']['kind']);
        $this->assertSame(0, $byKind['forest-friends']['sticker_count']);
    }

    public function test_the_detail_view_lists_the_sets(): void
    {
        $this->publishStickerPack();

        $this->getJson('/api/v1/packs/sticker-sheet')
            ->assertOk()
            ->assertJsonPath('pack.kind', Pack::KIND_STICKER_SET)
            ->assertJsonPath('pack.sticker_sets.0.set_uid', 'sheet-stickers-2026')
            ->assertJsonPath('pack.sticker_sets.0.sticker_count', 3);
    }

    public function test_a_free_sticker_pack_rides_the_free_entitlement_path(): void
    {
        $this->publishStickerPack(free: true);

        $user = User::factory()->create();
        $token = $this->issueDeviceToken($user);

        // A free pack grants itself on first fetch — unchanged by BL-37,
        // because entitlements never looked at what a pack contains.
        $this->withToken($token)
            ->getJson('/api/v1/packs/sticker-sheet/manifest')
            ->assertOk()
            ->assertJsonPath('kind', Pack::KIND_STICKER_SET);

        $this->withToken($token)
            ->getJson('/api/v1/entitlements')
            ->assertOk()
            ->assertJsonPath('0.pack_slug', 'sticker-sheet')
            ->assertJsonPath('0.source', 'free');
    }

    public function test_an_entitled_device_can_fetch_one_sticker_for_a_delta(): void
    {
        $this->publishStickerPack();

        $user = User::factory()->create();
        $token = $this->issueDeviceToken($user);

        $this->withToken($token)->getJson('/api/v1/packs/sticker-sheet/manifest')->assertOk();

        // BL-26's per-file route, unchanged: the allow-list is the manifest's
        // `files` map, and a sticker is a key in it like any other artifact.
        $this->withToken($token)
            ->get('/api/v1/packs/sticker-sheet/files/stickers/sheet-stickers-2026/star.png')
            ->assertRedirect();
    }

    // ------------------------------------------------ the structural checks --

    public function test_a_sticker_manifest_with_no_sets_is_refused(): void
    {
        $errors = $this->validate(['sticker_sets' => []]);

        $this->assertNotEmpty($errors);
        $this->assertStringContainsString('sticker_sets must be a non-empty array', implode(' ', $errors));
    }

    public function test_a_sticker_whose_image_is_not_in_the_file_map_is_refused(): void
    {
        $manifest = $this->fixtureManifest();
        $manifest['sticker_sets'][0]['stickers'][0]['image'] = 'stickers/sheet-stickers-2026/nope.png';

        $errors = $this->validate($manifest);

        $this->assertStringContainsString('is not listed in files', implode(' ', $errors));
    }

    public function test_a_repeated_sticker_id_within_one_set_is_refused(): void
    {
        $manifest = $this->fixtureManifest();
        $manifest['sticker_sets'][0]['stickers'][1]['sticker_id'] = 'star';

        $errors = $this->validate($manifest);

        $this->assertStringContainsString('repeats sticker_id "star"', implode(' ', $errors));
    }

    public function test_a_set_uid_owned_by_another_pack_is_refused(): void
    {
        $this->publishStickerPack();

        $manifest = $this->fixtureManifest();
        $manifest['pack_slug'] = 'somebody-else';

        $errors = $this->validate($manifest);

        $this->assertStringContainsString('already belongs to a different pack', implode(' ', $errors));
    }

    /**
     * BL-38 — `anim` is optional, and the fixture pack has none. A manifest
     * written before animation existed must still validate clean, because every
     * pack already installed on a device is one.
     */
    public function test_a_manifest_with_no_anim_is_still_valid(): void
    {
        $this->assertSame([], $this->validate([]));
    }

    public function test_a_malformed_anim_is_refused(): void
    {
        $manifest = $this->fixtureManifest();
        $manifest['sticker_sets'][0]['stickers'][0]['anim'] = ['hframes' => 4];

        $errors = $this->validate($manifest);

        $this->assertStringContainsString('anim that is not', implode(' ', $errors));
    }

    public function test_an_anim_claiming_more_frames_than_cells_is_refused(): void
    {
        $manifest = $this->fixtureManifest();
        $manifest['sticker_sets'][0]['stickers'][0]['anim'] = [
            'hframes' => 2, 'vframes' => 2, 'frames' => 9, 'fps' => 12,
        ];

        $errors = $this->validate($manifest);

        $this->assertStringContainsString('only holds 4', implode(' ', $errors));
    }

    public function test_an_anim_with_an_absurd_fps_is_refused(): void
    {
        $manifest = $this->fixtureManifest();
        $manifest['sticker_sets'][0]['stickers'][0]['anim'] = [
            'hframes' => 2, 'vframes' => 2, 'frames' => 4, 'fps' => 240,
        ];

        $errors = $this->validate($manifest);

        $this->assertStringContainsString('outside 1-30', implode(' ', $errors));
    }

    public function test_an_unknown_kind_is_refused_rather_than_read_as_a_book(): void
    {
        $errors = $this->validate(['kind' => 'wallpaper']);

        $this->assertStringContainsString('is not content this server serves', implode(' ', $errors));
    }

    /**
     * @return array<string, mixed>
     */
    private function fixtureManifest(): array
    {
        /** @var array<string, mixed> */
        return json_decode(
            (string) file_get_contents($this->stickerPackFixturePath().'/manifest.json'),
            true,
        );
    }

    /**
     * @param  array<string, mixed>  $overrides
     * @return array<int, string>
     */
    private function validate(array $overrides): array
    {
        $manifest = new PackManifest([...$this->fixtureManifest(), ...$overrides]);

        return app(PackManifestValidator::class)
            ->validate($manifest, $this->stickerPackFixturePath());
    }
}
