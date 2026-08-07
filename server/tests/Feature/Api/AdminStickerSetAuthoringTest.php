<?php

namespace Tests\Feature\Api;

use App\Models\AuthoredSticker;
use App\Models\AuthoredStickerSet;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\Sticker;
use App\Models\StickerSet;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\AdminsPacks;
use Tests\Concerns\AuthorsStickerSets;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * BL-37 — sticker-set authoring through the token door.
 *
 * The order of these tests is the flow, because the flow is the feature: create
 * a set → add stickers → each one is judged by `StickerValidation` on the way in
 * → publish when, and only when, every one of them is clean.
 *
 * **Nothing is faked.** BL-24's book tests have to stub the mapping pipeline
 * because it shells out to an engine; a sticker has no regions and therefore no
 * pipeline, so this whole path is real from the upload to the zip — which is
 * exactly the simplification §10.3 promised the sticker publish path would be.
 */
class AdminStickerSetAuthoringTest extends TestCase
{
    use AdminsPacks, AuthorsStickerSets, PublishesPacks, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakePackStorage();
    }

    // ------------------------------------------------------------- gating --

    public function test_a_game_token_cannot_author_sticker_sets(): void
    {
        $user = User::factory()->admin()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/admin/sticker-sets')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'MISSING_ABILITY');
    }

    public function test_authoring_sticker_sets_needs_a_token_at_all(): void
    {
        $this->getJson('/api/v1/admin/sticker-sets')
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'UNAUTHENTICATED');
    }

    // -------------------------------------------------------------- sets ---

    public function test_creating_a_set_creates_its_one_set_draft_pack(): void
    {
        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/sticker-sets', [
                'set_uid' => 'starter-stickers-2026',
                'title' => 'Starter Stickers',
                'blurb' => 'Eight simple stickers.',
                'is_free' => true,
                'sort_order' => 10,
            ])
            ->assertCreated()
            ->assertJsonPath('sticker_set.set_uid', 'starter-stickers-2026')
            ->assertJsonPath('sticker_set.pack_slug', 'starter-stickers-2026')
            ->assertJsonPath('sticker_set.pack_kind', Pack::KIND_STICKER_SET)
            ->assertJsonPath('sticker_set.pack_status', Pack::STATUS_DRAFT)
            ->assertJsonPath('sticker_set.is_free', true)
            ->assertJsonPath('sticker_set.sticker_count', 0)
            // An empty set is not publishable, and says so in the operator's
            // language rather than by a bare false.
            ->assertJsonPath('sticker_set.publishable', false);

        $pack = Pack::query()->where('slug', 'starter-stickers-2026')->sole();

        $this->assertSame(Pack::KIND_STICKER_SET, $pack->kind);
        $this->assertSame(Pack::STATUS_DRAFT, $pack->status);
    }

    public function test_a_set_uid_cannot_collide_with_a_book_or_another_set(): void
    {
        $this->withToken($this->adminToken());

        $this->postJson('/api/v1/admin/sticker-sets', [
            'set_uid' => 'starter-stickers-2026', 'title' => 'Starter',
        ])->assertCreated();

        // Same uid again.
        $this->postJson('/api/v1/admin/sticker-sets', [
            'set_uid' => 'starter-stickers-2026', 'title' => 'Again',
        ])->assertStatus(422)->assertJsonPath('error.code', 'VALIDATION_FAILED');

        // ...and a book already owning that slug blocks it too: `packs.slug` is
        // one namespace on the wire, whatever the content is.
        $this->postJson('/api/v1/admin/books', [
            'book_uid' => 'coyote-2026', 'title' => 'Coyote',
        ])->assertCreated();

        $this->postJson('/api/v1/admin/sticker-sets', [
            'set_uid' => 'coyote-2026', 'title' => 'Not a book',
        ])->assertStatus(422);
    }

    public function test_a_set_uid_must_be_a_plain_slug(): void
    {
        $this->withToken($this->adminToken())
            ->postJson('/api/v1/admin/sticker-sets', [
                'set_uid' => 'Starter Stickers!', 'title' => 'Starter',
            ])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED');
    }

    // ----------------------------------------------------------- stickers --

    public function test_a_sticker_is_validated_on_the_way_in(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 0);

        $this->post("/api/v1/admin/sticker-sets/{$set->set_uid}/stickers", [
            'image' => $this->stickerUpload('star.png'),
            'sticker_id' => 'star',
            'title' => 'Star',
        ])
            ->assertCreated()
            ->assertJsonPath('sticker.sticker_id', 'star')
            ->assertJsonPath('sticker.sticker_index', 0)
            // No queue, no polling, no mapping_status: the verdict is already
            // here (§10.3 — "validation is image checks only").
            ->assertJsonPath('sticker.publishable', true)
            ->assertJsonPath('sticker.validation_errors', [])
            ->assertJsonPath('sticker.image_size', [64, 64])
            ->assertJsonPath('sticker.file_name', 'star.png');

        /** @var AuthoredSticker $sticker */
        $sticker = AuthoredSticker::query()->sole();

        $this->assertSame('sticker', $sticker->imageAsset->kind);
    }

    public function test_a_sticker_too_small_to_use_is_refused_in_plain_language(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 0);

        $response = $this->post("/api/v1/admin/sticker-sets/{$set->set_uid}/stickers", [
            'image' => $this->tinyStickerUpload(),
            'sticker_id' => 'speck',
        ])->assertCreated();

        // The upload is KEPT — the operator can see what they uploaded and
        // replace it — but the row is not publishable, and the reason is a
        // sentence, not a code.
        $this->assertFalse($response->json('sticker.publishable'));
        $this->assertNotEmpty($response->json('sticker.validation_errors'));
        $this->assertStringContainsString('8x8', (string) $response->json('sticker.validation_errors.0'));
    }

    public function test_a_sticker_id_is_unique_within_its_set_but_not_across_sets(): void
    {
        $this->withToken($this->adminToken());

        $first = $this->authorStickerSet('first-stickers-2026', stickers: 1);

        // Same id, same set: refused.
        $this->post("/api/v1/admin/sticker-sets/{$first->set_uid}/stickers", [
            'image' => $this->stickerUpload('heart.png'),
            'sticker_id' => 'star',
        ])->assertStatus(422);

        // Same id, a DIFFERENT set: fine. A saved placement names the pair
        // (set_uid, sticker_id), so two sets may both offer a `star`.
        $second = $this->authorStickerSet('second-stickers-2026', stickers: 0);

        $this->post("/api/v1/admin/sticker-sets/{$second->set_uid}/stickers", [
            'image' => $this->stickerUpload('star.png'),
            'sticker_id' => 'star',
        ])->assertCreated();
    }

    public function test_replacing_a_sticker_image_revalidates_it(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 1);

        $this->assertTrue($this->stickersOf($set)[0]->isPublishable());

        $this->post("/api/v1/admin/sticker-sets/{$set->set_uid}/stickers/0", [
            '_method' => 'PATCH',
            'image' => $this->tinyStickerUpload(),
        ])
            ->assertOk()
            // The verdict travels with the art in the same call — there is no
            // window in which yesterday's verdict sits beside today's image.
            ->assertJsonPath('sticker.publishable', false);
    }

    public function test_reordering_renumbers_the_whole_set(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 3);

        $this->patchJson("/api/v1/admin/sticker-sets/{$set->set_uid}/stickers/2", [
            'sticker_index' => 0,
        ])->assertOk()->assertJsonPath('sticker.sticker_index', 0);

        $indexes = collect($this->stickersOf($set->refresh()))->pluck('sticker_index')->all();

        $this->assertSame([0, 1, 2], $indexes, 'the set is renumbered to a dense run');
        $this->assertSame('moon', $this->stickersOf($set)[0]->sticker_id);
    }

    public function test_deleting_a_sticker_closes_the_gap(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 3);

        $this->deleteJson("/api/v1/admin/sticker-sets/{$set->set_uid}/stickers/1")
            ->assertNoContent();

        $stickers = $this->stickersOf($set->refresh());

        $this->assertCount(2, $stickers);
        $this->assertSame([0, 1], collect($stickers)->pluck('sticker_index')->all());
        $this->assertSame(['star', 'moon'], collect($stickers)->pluck('sticker_id')->all());
    }

    public function test_the_editor_can_fetch_a_stickers_own_image(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 1);

        $this->get("/api/v1/admin/sticker-sets/{$set->set_uid}/stickers/0/image")
            ->assertOk()
            ->assertHeader('Content-Type', 'image/png');
    }

    // ------------------------------------------------------------ publish --

    public function test_publishing_an_empty_set_is_refused_with_a_reason(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 0);

        $this->postJson("/api/v1/admin/sticker-sets/{$set->set_uid}/publish")
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'STICKER_SET_NOT_PUBLISHABLE')
            ->assertJsonCount(1, 'error.details.errors');

        $this->assertSame(0, PackVersion::query()->count());
    }

    public function test_publishing_refuses_while_a_sticker_is_failing_and_names_every_one(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 1);

        $this->post("/api/v1/admin/sticker-sets/{$set->set_uid}/stickers", [
            'image' => $this->tinyStickerUpload(),
            'sticker_id' => 'speck',
        ])->assertCreated();

        $response = $this->postJson("/api/v1/admin/sticker-sets/{$set->set_uid}/publish")
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'STICKER_SET_NOT_PUBLISHABLE');

        /** @var list<string> $errors */
        $errors = $response->json('error.details.errors');

        $this->assertNotEmpty($errors);
        $this->assertStringContainsString('speck', implode(' ', $errors));
        $this->assertSame(0, PackVersion::query()->count());
    }

    public function test_the_one_button_publishes_a_sticker_pack(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 3);

        $this->postJson("/api/v1/admin/sticker-sets/{$set->set_uid}/publish")
            ->assertCreated()
            ->assertJsonPath('pack_slug', $set->set_uid)
            ->assertJsonPath('kind', Pack::KIND_STICKER_SET)
            ->assertJsonPath('version', 1)
            ->assertJsonPath('status', 'published');

        /** @var PackVersion $version */
        $version = PackVersion::query()->sole();

        // The manifest says what it carries, and carries the §7.2 sticker
        // payload rather than a books[] array.
        $this->assertSame(Pack::KIND_STICKER_SET, $version->manifest['kind']);
        $this->assertArrayNotHasKey('books', $version->manifest);
        $this->assertCount(1, $version->manifest['sticker_sets']);
        $this->assertCount(3, $version->manifest['sticker_sets'][0]['stickers']);

        // Files are named after the STABLE id, never the index (BL-26's delta).
        $this->assertArrayHasKey(
            'stickers/'.$set->set_uid.'/star.png',
            $version->manifest['files'],
        );

        // ...and `sticker_set.json` is synthesised into the install tree, so
        // StickerSetDef.discover() never has to open the manifest (§7.2).
        $this->assertArrayHasKey(
            'stickers/'.$set->set_uid.'/sticker_set.json',
            $version->manifest['files'],
        );

        // The catalog projection exists and the pack is live.
        $this->assertSame(Pack::STATUS_PUBLISHED, $version->pack->refresh()->status);
        $this->assertSame(1, StickerSet::query()->count());
        $this->assertSame(3, Sticker::query()->count());
        $this->assertSame($set->set_uid, StickerSet::query()->sole()->set_uid);
    }

    public function test_publishing_again_is_a_new_immutable_version(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 2);

        $this->postJson("/api/v1/admin/sticker-sets/{$set->set_uid}/publish")->assertCreated();

        $this->post("/api/v1/admin/sticker-sets/{$set->set_uid}/stickers", [
            'image' => $this->stickerUpload('moon.png'),
            'sticker_id' => 'moon',
        ])->assertCreated();

        $this->postJson("/api/v1/admin/sticker-sets/{$set->set_uid}/publish")
            ->assertCreated()
            ->assertJsonPath('version', 2);

        $this->assertSame(2, PackVersion::query()->count());
        // The catalog is rebuilt from the NEWEST release, never merged.
        $this->assertSame(3, Sticker::query()->count());
    }

    public function test_a_published_sets_sticker_ids_are_frozen(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 1);

        // Before publishing, renaming is fine.
        $this->patchJson("/api/v1/admin/sticker-sets/{$set->set_uid}/stickers/0", [
            'sticker_id' => 'big-star',
        ])->assertOk()->assertJsonPath('sticker.sticker_id', 'big-star');

        $this->postJson("/api/v1/admin/sticker-sets/{$set->set_uid}/publish")->assertCreated();

        // ...and afterwards it is not: a child has that id stuck on a page.
        $this->patchJson("/api/v1/admin/sticker-sets/{$set->set_uid}/stickers/0", [
            'sticker_id' => 'huge-star',
        ])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'STICKER_ID_FROZEN');
    }

    // ------------------------------------------------------------- delete --

    public function test_deleting_an_unpublished_set_removes_it_outright(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 1);

        $this->deleteJson("/api/v1/admin/sticker-sets/{$set->set_uid}")
            ->assertOk()
            ->assertJsonPath('outcome', 'deleted');

        $this->assertSame(0, AuthoredStickerSet::query()->count());
        $this->assertSame(0, Pack::query()->where('slug', $set->set_uid)->count());
    }

    public function test_deleting_a_published_set_retires_its_pack_instead(): void
    {
        $this->withToken($this->adminToken());
        $set = $this->authorStickerSet(stickers: 1);

        $this->postJson("/api/v1/admin/sticker-sets/{$set->set_uid}/publish")->assertCreated();

        $this->deleteJson("/api/v1/admin/sticker-sets/{$set->set_uid}")
            ->assertOk()
            ->assertJsonPath('outcome', 'retired');

        // §7.3: delisting must never take content off a device that has it —
        // and a removed sticker set would empty pages that are already coloured.
        $this->assertSame(0, AuthoredStickerSet::query()->count());
        $this->assertSame(
            Pack::STATUS_RETIRED,
            Pack::query()->where('slug', $set->set_uid)->sole()->status,
        );
    }
}
