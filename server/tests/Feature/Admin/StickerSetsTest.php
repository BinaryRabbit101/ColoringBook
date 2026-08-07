<?php

namespace Tests\Feature\Admin;

use App\Models\AuthoredSticker;
use App\Models\AuthoredStickerSet;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\AdminsPacks;
use Tests\Concerns\AuthorsStickerSets;
use Tests\Concerns\PaintsPages;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * BL-37 — sticker-set authoring in the browser.
 *
 * The Inertia half. Same actions, same FormRequests, same publish path as the
 * token door; what these tests are for is the *differences*: a 404 rather than a
 * 403 for a parent who guesses the URL, and a refused publish that bounces back
 * to the set with the whole list of reasons instead of a 422 nobody in a browser
 * would ever read.
 */
class StickerSetsTest extends TestCase
{
    // PaintsPages is here for `useSessionGuard()` alone: `auth:sanctum`
    // rewrites the default guard for the rest of the process, so a test that
    // hits the API and then the dashboard has to put it back.
    use AdminsPacks, AuthorsStickerSets, PaintsPages, PublishesPacks, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakePackStorage();
    }

    public function test_an_ordinary_parent_gets_a_404(): void
    {
        $user = User::factory()->create();

        $this->actingAs($user)->get('/admin/sticker-sets')->assertNotFound();
        $this->actingAs($user)
            ->post('/admin/sticker-sets', ['set_uid' => 'sneaky-2026', 'title' => 'Sneaky'])
            ->assertNotFound();

        $this->assertSame(0, AuthoredStickerSet::query()->count());
    }

    public function test_a_signed_out_visitor_is_sent_to_login(): void
    {
        $this->get('/admin/sticker-sets')->assertRedirect(route('login'));
    }

    public function test_the_set_list_renders(): void
    {
        AuthoredStickerSet::factory()->create([
            'set_uid' => 'starter-stickers-2026',
            'title' => 'Starter Stickers',
        ]);

        $this->actingAs(User::factory()->admin()->create())
            ->get('/admin/sticker-sets')
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('admin/StickerSets')
                ->has('stickerSets', 1)
                ->where('stickerSets.0.set_uid', 'starter-stickers-2026')
                ->where('stickerSets.0.pack_kind', Pack::KIND_STICKER_SET)
                // An empty set cannot publish, and the button reads that flag.
                ->where('stickerSets.0.publishable', false),
            );
    }

    public function test_creating_a_set_lands_on_its_editor(): void
    {
        $this->actingAs(User::factory()->admin()->create())
            ->post('/admin/sticker-sets', [
                'set_uid' => 'starter-stickers-2026',
                'title' => 'Starter Stickers',
                'is_free' => '1',
            ])
            ->assertRedirect('/admin/sticker-sets/starter-stickers-2026');

        $pack = Pack::query()->where('slug', 'starter-stickers-2026')->sole();

        // One-set pack, slug = uid, kind = sticker_set, draft until published.
        $this->assertSame(Pack::KIND_STICKER_SET, $pack->kind);
        $this->assertSame(Pack::STATUS_DRAFT, $pack->status);
        $this->assertTrue($pack->is_free);
    }

    public function test_the_editor_shows_the_stickers_and_their_verdicts(): void
    {
        $admin = User::factory()->admin()->create();
        $set = AuthoredStickerSet::factory()->create(['set_uid' => 'starter-stickers-2026']);

        AuthoredSticker::factory()->for($set, 'set')->create([
            'sticker_index' => 0, 'sticker_id' => 'star',
        ]);
        AuthoredSticker::factory()->for($set, 'set')->invalid()->create([
            'sticker_index' => 1, 'sticker_id' => 'speck',
        ]);

        $this->actingAs($admin)
            ->get('/admin/sticker-sets/starter-stickers-2026')
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('admin/StickerSet')
                ->has('stickerSet.stickers', 2)
                ->where('stickerSet.stickers.0.publishable', true)
                ->where('stickerSet.stickers.1.publishable', false)
                ->where('stickerSet.unpublishable_sticker_count', 1)
                ->where('stickerSet.publishable', false)
                ->where('publishErrors', []),
            );
    }

    public function test_a_refused_publish_bounces_with_the_whole_list(): void
    {
        $admin = User::factory()->admin()->create();
        $set = AuthoredStickerSet::factory()->create(['set_uid' => 'starter-stickers-2026']);

        AuthoredSticker::factory()->for($set, 'set')->invalid('its image is broken.')->create([
            'sticker_index' => 0, 'sticker_id' => 'speck',
        ]);
        AuthoredSticker::factory()->for($set, 'set')->invalid('its image is broken.')->create([
            'sticker_index' => 1, 'sticker_id' => 'smudge',
        ]);

        $this->actingAs($admin)
            ->post('/admin/sticker-sets/starter-stickers-2026/publish')
            ->assertRedirect('/admin/sticker-sets/starter-stickers-2026')
            // BOTH reasons, in one bounce: an operator with two broken images
            // must not have to press publish twice to learn about the second.
            ->assertSessionHas('sticker_set_errors', fn (array $errors): bool => count($errors) === 2);

        $this->assertSame(0, PackVersion::query()->count());
    }

    public function test_the_one_button_publishes_from_the_browser(): void
    {
        $admin = User::factory()->admin()->create();

        // Authored through the API concern, then published through the browser:
        // both doors are the same actions, which is the whole point of the split.
        $this->withToken($this->adminToken($admin));
        $set = $this->authorStickerSet(stickers: 2);
        $this->useSessionGuard();

        $this->actingAs($admin)
            ->post("/admin/sticker-sets/{$set->set_uid}/publish")
            ->assertRedirect("/admin/sticker-sets/{$set->set_uid}")
            ->assertSessionMissing('sticker_set_errors');

        $this->assertSame(1, PackVersion::query()->count());
        $this->assertSame(
            Pack::KIND_STICKER_SET,
            PackVersion::query()->sole()->pack->kind,
        );
    }

    public function test_a_sticker_can_be_added_and_removed_from_the_browser(): void
    {
        $admin = User::factory()->admin()->create();
        AuthoredStickerSet::factory()->create(['set_uid' => 'starter-stickers-2026']);

        $this->actingAs($admin)
            ->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
                'image' => $this->stickerUpload('star.png'),
                'sticker_id' => 'star',
                'title' => 'Star',
            ])
            ->assertRedirect('/admin/sticker-sets/starter-stickers-2026');

        $this->assertSame(1, AuthoredSticker::query()->count());
        $this->assertTrue(AuthoredSticker::query()->sole()->isPublishable());

        $this->actingAs($admin)
            ->delete('/admin/sticker-sets/starter-stickers-2026/stickers/0')
            ->assertRedirect('/admin/sticker-sets/starter-stickers-2026');

        $this->assertSame(0, AuthoredSticker::query()->count());
    }
}
