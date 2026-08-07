<?php

namespace App\Http\Controllers\Settings;

use App\Actions\Sync\EraseShelf;
use App\Http\Controllers\Controller;
use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\User;
use App\Services\ShelfClock;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Collection;
use Inertia\Inertia;
use Inertia\Response as InertiaResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * The parent dashboard's progress page — "erase everything" (BL-18).
 *
 * BL-18's option 1, and the reason it is the clean answer: the grown-up is
 * already here. Pressing the button in the game erases one tablet and then has
 * to argue with the server about it; pressing it here erases the thing every
 * tablet pulls from, and the argument never happens.
 *
 * One shelf per row — the account's own, plus one per child — because
 * `book_progress` is keyed that way and because a parent erasing one child's
 * shelf must not touch the other's. Each row says what is actually on it, so
 * the button is never pressed blind.
 *
 * Session auth, never a token: a game token can push and pull all day, but
 * wiping a household's colouring is a grown-up's decision made on a grown-up's
 * screen (§4.1) — the same rule the pictures page follows.
 */
class ProgressController extends Controller
{
    public function __construct(private readonly ShelfClock $clock) {}

    public function index(Request $request): InertiaResponse
    {
        return Inertia::render('settings/Progress', [
            'shelves' => $this->shelves($this->user($request)),
        ]);
    }

    /**
     * Wipe one shelf. `{shelf}` is a child's ULID, or `account` for the shelf
     * that has no profile — spelled out rather than left as an empty segment
     * so the route reads the same as the thing it deletes.
     */
    public function destroy(Request $request, string $shelf, EraseShelf $erase): RedirectResponse
    {
        $user = $this->user($request);
        $profile = $this->profile($user, $shelf);

        $outcome = $erase->handle($user, $profile);

        Inertia::flash('toast', [
            'type' => 'success',
            'message' => $outcome->books === 0
                ? __('That shelf was already empty.')
                : __(':books book(s) and :pictures picture(s) erased.', [
                    'books' => $outcome->books,
                    'pictures' => $outcome->pictures,
                ]),
        ]);

        return to_route('progress.edit');
    }

    /**
     * Every shelf on the account, empty ones included.
     *
     * An empty shelf is still listed: "there is nothing here" is the answer a
     * parent came to check, and hiding the row would leave them wondering
     * whether the wipe worked.
     *
     * @return list<array<string, mixed>>
     */
    private function shelves(User $user): array
    {
        $progress = BookProgress::query()
            ->where('user_id', $user->id)
            ->withCount('paintLayers')
            ->orderBy('book_uid')
            ->get()
            ->groupBy(fn (BookProgress $row): int => (int) $row->child_profile_id);

        $shelves = [$this->shelf($user, null, $progress->get(0))];

        foreach ($user->childProfiles()->orderBy('nickname')->get() as $profile) {
            $shelves[] = $this->shelf($user, $profile, $progress->get($profile->id));
        }

        return $shelves;
    }

    /**
     * @param  Collection<int, BookProgress>|null  $rows
     * @return array<string, mixed>
     */
    private function shelf(User $user, ?ChildProfile $profile, $rows): array
    {
        $rows ??= collect();
        $erasedAt = $this->clock->erasedAt($user, $profile);

        return [
            'key' => $profile === null ? 'account' : $profile->ulid,
            'name' => $profile?->nickname,
            'books' => $rows->map(fn (BookProgress $row): array => [
                'book_uid' => $row->book_uid,
                'pictures' => (int) $row->paint_layers_count,
            ])->values()->all(),
            'pictures' => (int) $rows->sum('paint_layers_count'),
            'erased_at' => $erasedAt?->toIso8601String(),
        ];
    }

    /**
     * `account` is the shelf with no profile. Anything else must be one of
     * *this* user's children — another household's ULID is a 404, never a 403,
     * the rule every other dashboard page follows.
     */
    private function profile(User $user, string $shelf): ?ChildProfile
    {
        if ($shelf === 'account') {
            return null;
        }

        return $user->childProfiles()->where('ulid', $shelf)->firstOrFail();
    }

    private function user(Request $request): User
    {
        $user = $request->user();

        abort_unless($user instanceof User, Response::HTTP_UNAUTHORIZED);

        return $user;
    }
}
