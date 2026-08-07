<?php

namespace App\Actions\Sync;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\User;
use App\Services\ProgressMerge;
use App\Services\ProgressPush;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;

/**
 * Apply one pushed book to one shelf, under the §6.3 protocol.
 *
 * Three outcomes, and only three:
 *
 * - **No row yet** — the book is created at revision 1 holding exactly what
 *   the device sent. `base_revision` is deliberately ignored here: if a device
 *   thinks the server has a row and it doesn't (the account was deleted and
 *   remade, say), recreating the progress is the answer that never loses a
 *   child's colouring.
 * - **`base_revision` matches** — the stored state and the pushed state are
 *   merged and the revision bumped. If the merge changes nothing, the write is
 *   skipped and the revision stands: re-syncing an unchanged book is free and,
 *   more importantly, doesn't touch `updated_at` and so doesn't wake every
 *   other device on the account through the `since` cursor.
 * - **`base_revision` is stale** — nothing is written. The server row goes
 *   back to the device, which merges and retries once. The server does *not*
 *   merge on the device's behalf here: the design's protocol is that the
 *   losing side re-merges and re-pushes, which is what makes the retry
 *   converge in one round rather than ping-ponging.
 *
 * Each book gets its own transaction so one conflicted book in a batch never
 * rolls back its neighbours.
 *
 * ### The shelf's erase clock (BL-18)
 *
 * `$shelfErasedAt` is passed through to the merge, and it changes the "no row
 * yet" case in the one way that matters: a wipe **deletes** the rows, so a
 * device that slept through one arrives with a full shelf, a stale
 * `base_revision` and no row to conflict with. Left alone, "recreating
 * progress beats losing it" would resurrect everything the parent just erased.
 * Censoring the push first turns that into recreating an *empty* book, which
 * is what it should have been all along.
 */
class ApplyBookProgress
{
    public function __construct(private readonly ProgressMerge $merge) {}

    public function handle(
        User $user,
        ?ChildProfile $profile,
        ProgressPush $push,
        ?CarbonImmutable $shelfErasedAt = null,
    ): BookProgressOutcome {
        return DB::transaction(function () use ($user, $profile, $push, $shelfErasedAt): BookProgressOutcome {
            $progress = BookProgress::query()
                ->where('user_id', $user->id)
                ->forProfile($profile)
                ->where('book_uid', $push->bookUid)
                ->lockForUpdate()
                ->first();

            if ($progress === null) {
                return new BookProgressOutcome(
                    $this->create($user, $profile, $push, $shelfErasedAt),
                    conflict: false,
                );
            }

            if ($progress->revision !== $push->baseRevision) {
                return new BookProgressOutcome($progress, conflict: true);
            }

            $stored = $progress->toState();
            $merged = $this->merge->merge($stored, $push->state, $shelfErasedAt);

            if (! $stored->equals($merged)) {
                $progress->applyState($merged);
                $progress->revision++;
                $progress->save();
            }

            return new BookProgressOutcome($progress, conflict: false);
        });
    }

    private function create(
        User $user,
        ?ChildProfile $profile,
        ProgressPush $push,
        ?CarbonImmutable $shelfErasedAt,
    ): BookProgress {
        $progress = new BookProgress;

        $progress->user_id = $user->id;
        $progress->child_profile_id = $profile?->id;
        $progress->book_uid = $push->bookUid;
        $progress->revision = 1;

        $progress->applyState($push->state->censoredBy($shelfErasedAt))->save();

        return $progress;
    }
}
