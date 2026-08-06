<?php

namespace Tests\Feature\Settings;

use App\Models\ChildProfile;
use App\Models\PaintLayer;
use App\Models\RetainedPaintLayer;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\PaintsPages;
use Tests\TestCase;

/**
 * "Restore the older picture" — the parent-facing half of §6.3.
 *
 * The failure this exists for is the only genuinely upsetting one in the whole
 * sync design: a child's finished picture disappearing because another device
 * uploaded over it. Everything here is about that button working, and about it
 * being a grown-up's button.
 */
class PicturesPageTest extends TestCase
{
    use PaintsPages, RefreshDatabase;

    /**
     * A page that has already lost one race: two versions, one retained.
     *
     * @return array{0: User, 1: string}
     */
    private function contestedPage(?ChildProfile $profile = null): array
    {
        $user = $profile?->user ?? User::factory()->create();
        $bearer = $this->issueDeviceToken($user);
        $morning = CarbonImmutable::parse('2026-08-06 09:00:00');

        $this->upload($bearer, 'coyote-2026', 0, $this->png('morning'), $morning, $profile?->ulid)
            ->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('evening'), $morning->addHours(9), $profile?->ulid)
            ->assertCreated();

        return [$user, $bearer];
    }

    public function test_the_page_needs_a_signed_in_parent(): void
    {
        $this->get(route('pictures.edit'))->assertRedirect(route('login'));
    }

    public function test_a_page_with_nothing_to_restore_is_not_listed(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $this->upload($this->issueDeviceToken($user), 'coyote-2026', 0, $this->png())->assertCreated();

        $this->actingAs($user)
            ->get(route('pictures.edit'))
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('settings/Pictures')
                ->has('books', 0)
                ->where('retentionDays', 30),
            );
    }

    public function test_a_contested_page_is_listed_with_its_older_version(): void
    {
        $this->fakePaintStorage();
        [$user] = $this->contestedPage();

        $this->actingAs($user)
            ->get(route('pictures.edit'))
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('settings/Pictures')
                ->has('books', 1)
                ->where('books.0.book_uid', 'coyote-2026')
                // The account shelf has no child's name on it.
                ->where('books.0.shelf', null)
                ->has('books.0.pages', 1)
                // 1-based for a human, matching the file on disk.
                ->where('books.0.pages.0.page_number', 1)
                ->has('books.0.pages.0.older', 1)
                ->has('books.0.pages.0.older.0.expires_at')
                ->has('books.0.pages.0.older.0.painted_at')
                ->etc(),
            );
    }

    public function test_a_childs_book_is_listed_under_their_name(): void
    {
        $this->fakePaintStorage();
        $profile = ChildProfile::factory()->for(User::factory())->create(['nickname' => 'Ivy']);
        [$user] = $this->contestedPage($profile);

        $this->actingAs($user)
            ->get(route('pictures.edit'))
            ->assertOk()
            ->assertInertia(fn ($page) => $page->where('books.0.shelf', 'Ivy')->etc());
    }

    public function test_restoring_swaps_the_two_versions_over(): void
    {
        $disk = $this->fakePaintStorage();
        [$user] = $this->contestedPage();

        $retained = RetainedPaintLayer::query()->sole();
        $live = "{$user->ulid}/coyote-2026/page_01.png";

        $this->actingAs($user)
            ->post(route('pictures.restore', $retained->ulid))
            ->assertRedirect(route('pictures.edit'));

        // The morning picture is back where the game will fetch it…
        $this->assertSame($this->png('morning'), $disk->get($live));

        $layer = PaintLayer::query()->sole();
        $this->assertSame(hash('sha256', $this->png('morning')), $layer->sha256);
        $this->assertSame(3, $layer->revision);
        $this->assertSame($live, $layer->storage_path);

        // …and the evening picture took its place in retention, so the button
        // can never be the thing that loses a picture.
        $demoted = RetainedPaintLayer::query()->sole();
        $this->assertSame(hash('sha256', $this->png('evening')), $demoted->sha256);
        $this->assertSame($this->png('evening'), $disk->get($demoted->storage_path));
        $this->assertSame("{$user->ulid}/coyote-2026/page_01.2.png", $demoted->storage_path);
    }

    public function test_restoring_twice_puts_everything_back(): void
    {
        $disk = $this->fakePaintStorage();
        [$user] = $this->contestedPage();

        $this->actingAs($user)
            ->post(route('pictures.restore', RetainedPaintLayer::query()->sole()->ulid))
            ->assertRedirect();

        $this->actingAs($user)
            ->post(route('pictures.restore', RetainedPaintLayer::query()->sole()->ulid))
            ->assertRedirect();

        $this->assertSame(
            $this->png('evening'),
            $disk->get("{$user->ulid}/coyote-2026/page_01.png"),
        );
        $this->assertDatabaseCount('retained_paint_layers', 1);
    }

    public function test_the_game_can_fetch_the_restored_picture(): void
    {
        $this->fakePaintStorage();
        [$user, $bearer] = $this->contestedPage();

        $this->actingAs($user)
            ->post(route('pictures.restore', RetainedPaintLayer::query()->sole()->ulid))
            ->assertRedirect();

        $this->forgetResolvedGuards();

        $redirect = $this->withToken($bearer)->get('/api/v1/sync/paint/coyote-2026/0');
        $redirect->assertStatus(302);

        $this->assertSame(
            $this->png('morning'),
            $this->get((string) $redirect->headers->get('Location'))->streamedContent(),
        );
    }

    public function test_a_restored_picture_is_not_immediately_overwritten_again(): void
    {
        $this->fakePaintStorage();
        [$user, $bearer] = $this->contestedPage();

        $this->actingAs($user)
            ->post(route('pictures.restore', RetainedPaintLayer::query()->sole()->ulid))
            ->assertRedirect();

        $this->forgetResolvedGuards();

        // The device that won the first race re-pushes the picture the parent
        // just rejected, with its original (newer) timestamp. A restore that
        // kept the old timestamp would lose here, and the button would be a
        // lie.
        $this->upload(
            $bearer,
            'coyote-2026',
            0,
            $this->png('evening'),
            CarbonImmutable::parse('2026-08-06 18:00:00'),
        )->assertStatus(409)->assertJsonPath('error.code', 'PAINT_STALE');

        $this->assertSame(
            hash('sha256', $this->png('morning')),
            PaintLayer::query()->sole()->sha256,
        );
    }

    public function test_a_parent_cannot_restore_another_households_picture(): void
    {
        $this->fakePaintStorage();
        $this->contestedPage();

        $stranger = User::factory()->create();

        $this->actingAs($stranger)
            ->post(route('pictures.restore', RetainedPaintLayer::query()->sole()->ulid))
            ->assertNotFound();
    }

    public function test_a_game_token_cannot_restore_a_picture(): void
    {
        $this->fakePaintStorage();
        [, $bearer] = $this->contestedPage();

        // Choosing between two versions of a child's picture is a grown-up's
        // decision on a grown-up's screen (§4.1, §6.3).
        $this->useSessionGuard()
            ->withToken($bearer)
            ->postJson(route('pictures.restore', RetainedPaintLayer::query()->sole()->ulid))
            ->assertUnauthorized();

        $this->assertSame(
            hash('sha256', $this->png('evening')),
            PaintLayer::query()->sole()->sha256,
        );
    }
}
