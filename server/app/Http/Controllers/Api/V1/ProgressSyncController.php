<?php

namespace App\Http\Controllers\Api\V1;

use App\Actions\Sync\ApplyBookProgress;
use App\Actions\Sync\EraseShelf;
use App\Http\Controllers\Controller;
use App\Http\Requests\Sync\EraseProgressRequest;
use App\Http\Requests\Sync\FetchProgressRequest;
use App\Http\Requests\Sync\SyncProgressRequest;
use App\Http\Resources\BookProgressResource;
use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\User;
use App\Services\ShelfClock;
use Carbon\CarbonImmutable;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * `/api/v1/sync/progress` — DLC_SERVER.md §11 "Sync", §6.
 *
 * Progress is pulled on launch and on book open, and pushed at the existing
 * save points (§6.2). Both directions are scoped to one shelf: a child profile
 * if `profile` names one, the account itself if it doesn't.
 *
 * ### Conflicts are per book, inside a 200
 *
 * The design asks for "a per-book 409 with server state", but the call is
 * batched — one request covers the whole shelf, and a shelf where one book
 * conflicted and four synced cleanly has no single HTTP status. So the status
 * is always 200 and each result carries its own verdict:
 *
 *     {"book_uid": "coyote-2026", "revision": 4, "conflict": false}
 *     {"book_uid": "fox-2026",    "revision": 9, "conflict": true,
 *      "server": {…the full server state…}}
 *
 * A conflicted book was **not** written. Its `server` block is everything the
 * device needs to merge locally and retry that one book with
 * `base_revision: 9`, which is the entire protocol of §6.3.
 *
 * ### Erasure is a third verb (BL-18)
 *
 * `DELETE` wipes the shelf. It exists because the other two cannot say "this
 * is gone": the merge only ever climbs, so a device that erased locally and
 * then pushed would have the erasure merged straight back out of it. The wipe
 * records an instant on the shelf, and `GET` publishes that instant as
 * `erased_at` so every other device can censor itself against it — the state
 * that wins, in place of the absence that lost.
 */
class ProgressSyncController extends Controller
{
    public function __construct(private readonly ShelfClock $clock) {}

    /**
     * The shelf, or everything on it changed since a cursor.
     */
    public function index(FetchProgressRequest $request): JsonResponse
    {
        $user = $this->user($request);
        $profile = $this->profile($user, $request->profileUlid());

        // Taken before the read, deliberately. A client that stores this as
        // its next `since` can then only ever re-fetch a row it already had —
        // never miss one written while this query was running. Re-fetching is
        // free, because merging is idempotent.
        $serverTime = CarbonImmutable::now();

        $query = BookProgress::query()
            ->where('user_id', $user->id)
            ->forProfile($profile)
            ->orderBy('book_uid');

        if (($since = $request->since()) !== null) {
            // Formatted by hand: the query grammar's default date format has
            // no microseconds, and it is precisely the sub-second window that
            // the cursor must not lose (see BookProgress::DATE_FORMAT).
            $query->where('updated_at', '>', $since->format(BookProgress::DATE_FORMAT));
        }

        return response()->json([
            'books' => BookProgressResource::collection($query->get()),
            // Never filtered by `since`. A wipe leaves no rows behind, so the
            // clock is the only thing a cursored pull can learn it from — and
            // a device that has already converged simply re-reads the instant
            // it converged on, which is free.
            'erased_at' => $this->stamp($this->clock->erasedAt($user, $profile)),
            'server_time' => $this->cursor($serverTime),
        ]);
    }

    /**
     * Push the shelf. Batched, and per-book in its verdicts.
     */
    public function update(SyncProgressRequest $request, ApplyBookProgress $apply): JsonResponse
    {
        $user = $this->user($request);
        $profile = $this->profile($user, $request->profileUlid());

        $serverTime = CarbonImmutable::now();
        $erasedAt = $this->clock->erasedAt($user, $profile);
        $results = [];

        foreach ($request->pushes() as $push) {
            $outcome = $apply->handle($user, $profile, $push, $erasedAt);

            $result = [
                'book_uid' => $outcome->progress->book_uid,
                'revision' => $outcome->progress->revision,
                'conflict' => $outcome->conflict,
            ];

            if ($outcome->conflict) {
                $result['server'] = (new BookProgressResource($outcome->progress))->toArray($request);
            }

            $results[] = $result;
        }

        return response()->json([
            'results' => $results,
            'erased_at' => $this->stamp($erasedAt),
            'server_time' => $this->cursor($serverTime),
        ]);
    }

    /**
     * Wipe the shelf — BL-18, DLC_SERVER.md §6.3 "Erasure".
     *
     * The device's own "Erase all progress", pushed up. `erased_at` is the
     * instant the grown-up pressed the button on *that* tablet, not the moment
     * the request arrived, so an erase made on a plane still wins against
     * everything painted before it once the tablet finds a network again.
     *
     * Idempotent, which is what lets the client simply keep the instant in its
     * queue and re-send it until a drain succeeds: the clock only ever moves
     * forward, so replaying an erase changes nothing, and an erase older than
     * one already recorded is answered with the recorded one.
     */
    public function destroy(EraseProgressRequest $request, EraseShelf $erase): JsonResponse
    {
        $user = $this->user($request);
        $profile = $this->profile($user, $request->profileUlid());

        $serverTime = CarbonImmutable::now();
        $outcome = $erase->handle($user, $profile, $request->erasedAt());

        return response()->json([
            'erased_at' => $this->stamp($outcome->erasedAt),
            'books_erased' => $outcome->books,
            'pictures_erased' => $outcome->pictures,
            'server_time' => $this->cursor($serverTime),
        ]);
    }

    /**
     * Resolve the shelf. Absent `profile` is the account-level shelf; a ULID
     * that isn't one of *this* user's children is a 404, never a 403 — the
     * same rule the profile endpoints follow, so one account can't probe
     * another's for existence.
     */
    private function profile(User $user, ?string $ulid): ?ChildProfile
    {
        if ($ulid === null) {
            return null;
        }

        return $user->childProfiles()->where('ulid', $ulid)->firstOrFail();
    }

    /**
     * A cursor the client can hand straight back as `since`, microseconds and
     * all — at whole-second resolution a row written later in the same second
     * would never be pulled.
     */
    private function cursor(CarbonImmutable $at): string
    {
        return $at->utc()->format('Y-m-d\TH:i:s.up');
    }

    /**
     * The same microsecond ISO form for a clock that may not exist yet. Null
     * is "this shelf has never been erased" and is deliberately not the epoch.
     */
    private function stamp(?CarbonImmutable $at): ?string
    {
        return $at === null ? null : $this->cursor($at);
    }

    private function user(Request $request): User
    {
        $user = $request->user();

        abort_unless($user instanceof User, Response::HTTP_UNAUTHORIZED);

        return $user;
    }
}
