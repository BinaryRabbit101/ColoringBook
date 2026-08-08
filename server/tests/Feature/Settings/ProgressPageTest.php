<?php

namespace Tests\Feature\Settings;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\ShelfErasure;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\PaintsPages;
use Tests\TestCase;

/**
 * "Erase everything" from the parent dashboard — BL-18's option 1.
 *
 * The clean answer to "the button in the game doesn't stick": erase the thing
 * every device pulls from, where the grown-up already is. What these tests
 * hold onto is that it is *one shelf*, that it is a grown-up's route, and that
 * the clock it leaves behind is what makes the tablets converge.
 */
class ProgressPageTest extends TestCase
{
    use PaintsPages, RefreshDatabase;

    public function test_the_page_needs_a_signed_in_parent(): void
    {
        $this->get(route('progress.edit'))->assertRedirect(route('login'));
    }

    public function test_it_lists_the_account_shelf_and_every_child(): void
    {
        $this->fakePaintStorage();

        $user = User::factory()->create();
        $child = ChildProfile::factory()->for($user)->create(['nickname' => 'Robin']);
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('a'))->assertCreated();
        $this->upload($bearer, 'coyote-2026', 1, $this->png('b'))->assertCreated();

        $this->useSessionGuard()
            ->actingAs($user)
            ->get(route('progress.edit'))
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('settings/Progress')
                ->has('shelves', 2)
                ->where('shelves.0.key', 'account')
                ->where('shelves.0.name', null)
                ->where('shelves.0.pictures', 2)
                ->where('shelves.0.books.0.book_uid', 'coyote-2026')
                ->where('shelves.0.erased_at', null)
                ->where('shelves.1.key', $child->ulid)
                ->where('shelves.1.name', 'Robin')
                ->has('shelves.1.books', 0),
            );
    }

    public function test_erasing_a_shelf_deletes_its_rows_pictures_and_blobs(): void
    {
        $disk = $this->fakePaintStorage();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('a'))->assertCreated();
        $this->upload($bearer, 'fox-2026', 0, $this->png('b'))->assertCreated();
        $this->assertCount(2, $disk->allFiles());

        $this->useSessionGuard()
            ->actingAs($user)
            ->delete(route('progress.destroy', ['shelf' => 'account']))
            ->assertRedirect(route('progress.edit'));

        $this->assertSame(0, BookProgress::query()->count());
        $this->assertDatabaseCount('paint_layers', 0);
        $this->assertSame([], $disk->allFiles());
        $this->assertSame(1, ShelfErasure::query()->count());
    }

    /**
     * The whole reason the clock exists: the tablet that was off during the
     * wipe wakes up, pushes its shelf, and gets nowhere.
     */
    public function test_a_device_that_slept_through_the_wipe_converges_on_empty(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);
        $painted = CarbonImmutable::parse('2026-08-07 09:00:00');

        $this->withToken($bearer)->putJson('/api/v1/sync/progress', [
            'books' => [[
                'book_uid' => 'coyote-2026',
                'base_revision' => 0,
                'current_page_index' => 1,
                'page_statuses' => ['complete', 'complete'],
                'furthest_page_index' => 1,
                'client_updated_at' => $painted->toIso8601String(),
            ]],
        ])->assertOk();

        $this->useSessionGuard()
            ->actingAs($user)
            ->delete(route('progress.destroy', ['shelf' => 'account']))
            ->assertRedirect(route('progress.edit'));

        // The tablet, still holding what it held this morning.
        $this->forgetResolvedGuards()
            ->withToken($bearer)
            ->putJson('/api/v1/sync/progress', [
                'books' => [[
                    'book_uid' => 'coyote-2026',
                    'base_revision' => 1,
                    'current_page_index' => 1,
                    'page_statuses' => ['complete', 'complete'],
                    'furthest_page_index' => 1,
                    'client_updated_at' => $painted->toIso8601String(),
                ]],
            ])->assertOk();

        $row = BookProgress::query()->sole();
        $this->assertSame([], $row->pageStatuses());
        $this->assertSame(0, $row->furthest_page_index);
    }

    public function test_erasing_one_childs_shelf_leaves_the_rest_of_the_household(): void
    {
        $disk = $this->fakePaintStorage();

        $user = User::factory()->create();
        $robin = ChildProfile::factory()->for($user)->create(['nickname' => 'Robin']);
        $sam = ChildProfile::factory()->for($user)->create(['nickname' => 'Sam']);
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('robin'), null, $robin->ulid)->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('sam'), null, $sam->ulid)->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('everyone'))->assertCreated();

        $this->useSessionGuard()
            ->actingAs($user)
            ->delete(route('progress.destroy', ['shelf' => $robin->ulid]))
            ->assertRedirect(route('progress.edit'));

        $this->assertSame(2, BookProgress::query()->count());
        $this->assertSame(0, BookProgress::query()->where('child_profile_id', $robin->id)->count());
        $this->assertCount(2, $disk->allFiles());
    }

    public function test_the_page_reports_when_a_shelf_was_last_erased(): void
    {
        $user = User::factory()->create();

        $this->useSessionGuard()
            ->actingAs($user)
            ->delete(route('progress.destroy', ['shelf' => 'account']));

        $this->actingAs($user)
            ->get(route('progress.edit'))
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('settings/Progress')
                ->where('shelves.0.erased_at', fn (?string $at): bool => is_string($at)),
            );
    }

    public function test_another_households_child_is_a_404(): void
    {
        $user = User::factory()->create();
        $stranger = ChildProfile::factory()->for(User::factory())->create();

        $this->useSessionGuard()
            ->actingAs($user)
            ->delete(route('progress.destroy', ['shelf' => $stranger->ulid]))
            ->assertNotFound();

        $this->assertSame(0, ShelfErasure::query()->count());
    }

    /**
     * A game token can push and pull all day; wiping a household's colouring
     * is a grown-up's decision made on a grown-up's screen (§4.1). The same
     * rule the pictures page follows.
     */
    public function test_a_game_token_cannot_reach_the_dashboard_wipe(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        // Warm the sanctum guard the way a real game request would, so this
        // proves the route refuses a bearer token rather than that the guard
        // was never asked (see PaintsPages::useSessionGuard).
        $this->withToken($bearer)->getJson('/api/v1/sync/progress')->assertOk();

        $this->useSessionGuard()
            ->withToken($bearer)
            ->delete(route('progress.destroy', ['shelf' => 'account']))
            ->assertRedirect(route('login'));
    }
}
