<?php

namespace Tests\Feature\Admin;

use App\Models\AuthoredSticker;
use App\Models\AuthoredStickerSet;
use App\Models\PackVersion;
use App\Models\Sticker;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\AdminsPacks;
use Tests\Concerns\AuthorsStickerSets;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * BL-38 — animated stickers, end to end.
 *
 * The claim under test is the **contract**, because the game half is being built
 * against exactly this and nothing else: an animated sticker is a sprite-sheet
 * PNG plus `anim: {hframes, vframes, frames, fps}` on its manifest entry, and a
 * still sticker carries **no `anim` key at all**.
 *
 * That second half is the one worth a test of its own. "Absent" is what every
 * sticker published before BL-38 looks like, so a publisher that started writing
 * `"anim": null` would be a silent format change on packs already installed.
 */
class AnimatedStickersTest extends TestCase
{
    use AdminsPacks, AuthorsStickerSets, PublishesPacks, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakePackStorage();
    }

    private function admin(): User
    {
        return User::factory()->admin()->create();
    }

    public function test_a_sprite_sheet_is_stored_with_its_animation(): void
    {
        $admin = $this->admin();
        AuthoredStickerSet::factory()->create(['set_uid' => 'starter-stickers-2026']);

        $this->actingAs($admin)
            ->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
                'image' => $this->spriteSheetUpload(cols: 4, rows: 2, frame: 64),
                'sticker_id' => 'sparkle',
                'title' => 'Sparkle',
                'anim' => ['hframes' => 4, 'vframes' => 2, 'frames' => 7, 'fps' => 12],
            ])
            ->assertSessionHasNoErrors()
            ->assertRedirect('/admin/sticker-sets/starter-stickers-2026');

        $sticker = AuthoredSticker::query()->sole();

        $this->assertSame(
            ['hframes' => 4, 'vframes' => 2, 'frames' => 7, 'fps' => 12],
            $sticker->anim,
        );
        $this->assertTrue($sticker->isAnimated());
        // The sheet is 256x128 — refused by the still bounds in one direction,
        // fine once the checks look at ONE FRAME, which is the whole point.
        $this->assertTrue($sticker->isPublishable());
    }

    public function test_a_still_sticker_keeps_a_null_animation(): void
    {
        $admin = $this->admin();
        AuthoredStickerSet::factory()->create(['set_uid' => 'starter-stickers-2026']);

        // The form always posts the four fields; empty is a still sticker, not
        // a validation error and not a half-filled animation.
        $this->actingAs($admin)
            ->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
                'image' => $this->stickerUpload('star.png'),
                'sticker_id' => 'star',
                'anim' => ['hframes' => '', 'vframes' => '', 'frames' => '', 'fps' => ''],
            ])
            ->assertSessionHasNoErrors();

        $this->assertNull(AuthoredSticker::query()->sole()->anim);
    }

    public function test_a_half_filled_animation_is_refused(): void
    {
        $admin = $this->admin();
        AuthoredStickerSet::factory()->create(['set_uid' => 'starter-stickers-2026']);

        $this->actingAs($admin)
            ->from('/admin/sticker-sets/starter-stickers-2026')
            ->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
                'image' => $this->spriteSheetUpload(),
                'sticker_id' => 'sparkle',
                'anim' => ['hframes' => 4],
            ])
            ->assertSessionHasErrors(['anim.vframes', 'anim.frames', 'anim.fps']);

        $this->assertSame(0, AuthoredSticker::query()->count());
    }

    public function test_more_frames_than_cells_is_refused_by_the_form(): void
    {
        $admin = $this->admin();
        AuthoredStickerSet::factory()->create(['set_uid' => 'starter-stickers-2026']);

        $this->actingAs($admin)
            ->from('/admin/sticker-sets/starter-stickers-2026')
            ->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
                'image' => $this->spriteSheetUpload(cols: 2, rows: 2),
                'sticker_id' => 'sparkle',
                'anim' => ['hframes' => 2, 'vframes' => 2, 'frames' => 9, 'fps' => 12],
            ])
            ->assertSessionHasErrors('anim.frames');

        $this->assertSame(0, AuthoredSticker::query()->count());
    }

    public function test_an_out_of_range_fps_is_refused(): void
    {
        $admin = $this->admin();
        AuthoredStickerSet::factory()->create(['set_uid' => 'starter-stickers-2026']);

        $this->actingAs($admin)
            ->from('/admin/sticker-sets/starter-stickers-2026')
            ->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
                'image' => $this->spriteSheetUpload(),
                'sticker_id' => 'sparkle',
                'anim' => ['hframes' => 4, 'vframes' => 2, 'frames' => 8, 'fps' => 240],
            ])
            ->assertSessionHasErrors('anim.fps');
    }

    public function test_a_grid_that_does_not_divide_the_sheet_fails_validation(): void
    {
        $admin = $this->admin();
        AuthoredStickerSet::factory()->create(['set_uid' => 'starter-stickers-2026']);

        // A 300 px-wide sheet declared as 7 columns: the form cannot know,
        // because the four numbers are internally consistent. The pixels can,
        // and `StickerValidation` is where that lands.
        $this->actingAs($admin)
            ->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
                'image' => $this->spriteSheetUpload(cols: 3, rows: 1, frame: 100),
                'sticker_id' => 'sparkle',
                'anim' => ['hframes' => 7, 'vframes' => 1, 'frames' => 7, 'fps' => 10],
            ])
            ->assertSessionHasNoErrors();

        $sticker = AuthoredSticker::query()->sole();

        $this->assertFalse($sticker->isPublishable());
        $this->assertStringContainsString(
            'does not divide evenly',
            implode(' ', $sticker->validation_errors ?? []),
        );
    }

    public function test_changing_the_grid_revalidates_the_same_bytes(): void
    {
        $admin = $this->admin();
        AuthoredStickerSet::factory()->create(['set_uid' => 'starter-stickers-2026']);

        $this->actingAs($admin)->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
            'image' => $this->spriteSheetUpload(cols: 4, rows: 2, frame: 64),
            'sticker_id' => 'sparkle',
            'anim' => ['hframes' => 4, 'vframes' => 2, 'frames' => 8, 'fps' => 12],
        ]);

        $this->assertTrue(AuthoredSticker::query()->sole()->isPublishable());

        // Same image, a grid that no longer divides it. The verdict has to
        // follow the meaning of the bytes, not the bytes.
        $this->actingAs($admin)
            ->patch('/admin/sticker-sets/starter-stickers-2026/stickers/0', [
                'anim' => ['hframes' => 3, 'vframes' => 2, 'frames' => 6, 'fps' => 12],
            ])
            ->assertSessionHasNoErrors();

        $this->assertFalse(AuthoredSticker::query()->sole()->isPublishable());
    }

    public function test_clearing_the_animation_makes_it_a_still_sticker_again(): void
    {
        $admin = $this->admin();
        AuthoredStickerSet::factory()->create(['set_uid' => 'starter-stickers-2026']);

        $this->actingAs($admin)->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
            'image' => $this->spriteSheetUpload(cols: 2, rows: 2, frame: 128),
            'sticker_id' => 'sparkle',
            'anim' => ['hframes' => 2, 'vframes' => 2, 'frames' => 4, 'fps' => 8],
        ]);

        $this->actingAs($admin)->patch('/admin/sticker-sets/starter-stickers-2026/stickers/0', [
            'anim' => ['hframes' => '', 'vframes' => '', 'frames' => '', 'fps' => ''],
        ]);

        $this->assertNull(AuthoredSticker::query()->sole()->anim);
    }

    public function test_a_reorder_leaves_the_animation_alone(): void
    {
        $admin = $this->admin();
        AuthoredStickerSet::factory()->create(['set_uid' => 'starter-stickers-2026']);

        $this->actingAs($admin)->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
            'image' => $this->stickerUpload('star.png'),
            'sticker_id' => 'star',
        ]);
        $this->actingAs($admin)->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
            'image' => $this->spriteSheetUpload(cols: 2, rows: 2, frame: 128),
            'sticker_id' => 'sparkle',
            'anim' => ['hframes' => 2, 'vframes' => 2, 'frames' => 4, 'fps' => 8],
        ]);

        // The Up button posts `sticker_index` and nothing else — no `anim` key
        // at all, which must read as "leave it alone" and not "make it still".
        $this->actingAs($admin)
            ->patch('/admin/sticker-sets/starter-stickers-2026/stickers/1', ['sticker_index' => 0]);

        $moved = AuthoredSticker::query()->where('sticker_id', 'sparkle')->sole();

        $this->assertSame(0, $moved->sticker_index);
        $this->assertNotNull($moved->anim);
    }

    public function test_publishing_puts_anim_on_the_entry_and_omits_it_for_a_still_sticker(): void
    {
        $admin = $this->admin();
        AuthoredStickerSet::factory()->create([
            'set_uid' => 'starter-stickers-2026',
            'title' => 'Starter Stickers',
        ]);

        $this->actingAs($admin)->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
            'image' => $this->spriteSheetUpload(cols: 4, rows: 2, frame: 64),
            'sticker_id' => 'sparkle',
            'anim' => ['hframes' => 4, 'vframes' => 2, 'frames' => 7, 'fps' => 12],
        ]);
        $this->actingAs($admin)->post('/admin/sticker-sets/starter-stickers-2026/stickers', [
            'image' => $this->stickerUpload('star.png'),
            'sticker_id' => 'star',
        ]);

        $this->actingAs($admin)
            ->post('/admin/sticker-sets/starter-stickers-2026/publish')
            ->assertSessionMissing('sticker_set_errors');

        $manifest = PackVersion::query()->sole()->manifest;
        $entries = $manifest['sticker_sets'][0]['stickers'];

        $this->assertSame([
            'hframes' => 4,
            'vframes' => 2,
            'frames' => 7,
            'fps' => 12,
        ], $entries[0]['anim']);

        // The contract's other half: absent, not null.
        $this->assertArrayNotHasKey('anim', $entries[1]);

        // The self-describing per-set JSON carries it too — the client's
        // StickerSetDef reads that file and never opens the manifest (§7.2).
        $this->assertArrayHasKey(
            'stickers/starter-stickers-2026/sticker_set.json',
            $manifest['files'],
        );

        // …and the catalog projection keeps it, so the server can still answer
        // what the newest release contains.
        $this->assertSame(
            12,
            Sticker::query()->where('sticker_id', 'sparkle')->sole()->anim['fps'],
        );
        $this->assertNull(Sticker::query()->where('sticker_id', 'star')->sole()->anim);
    }

    public function test_an_animated_sticker_can_be_added_through_the_token_door(): void
    {
        $admin = $this->admin();
        $this->withToken($this->adminToken($admin));

        $this->postJson('/api/v1/admin/sticker-sets', [
            'set_uid' => 'starter-stickers-2026',
            'title' => 'Starter Stickers',
        ])->assertCreated();

        $this->post('/api/v1/admin/sticker-sets/starter-stickers-2026/stickers', [
            'image' => $this->spriteSheetUpload(cols: 2, rows: 2, frame: 128),
            'sticker_id' => 'sparkle',
            'anim' => ['hframes' => 2, 'vframes' => 2, 'frames' => 4, 'fps' => 10],
        ])
            ->assertCreated()
            ->assertJsonPath('sticker.anim.hframes', 2)
            ->assertJsonPath('sticker.anim.frames', 4)
            ->assertJsonPath('sticker.publishable', true);
    }
}
