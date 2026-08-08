<?php

namespace App\Services;

use App\Models\ChildProfile;
use App\Models\ShelfErasure;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;

/**
 * Reads and advances one shelf's erase clock (BL-18, DLC_SERVER.md §6.3).
 *
 * The clock is the only durable trace a wipe leaves — the progress rows and
 * the pictures are gone — so everything that touches it goes through here:
 * `GET /sync/progress` publishes it, `PUT /sync/progress` censors against it,
 * and both `DELETE /sync/progress` and the parent dashboard advance it.
 *
 * **Monotonic.** `record()` never moves the clock backwards. A device that has
 * been offline for a week and finally delivers a week-old erase must not undo
 * a wipe the parent did yesterday; and because the merge is `max` on both
 * ends, replaying the same erase any number of times is a no-op.
 */
class ShelfClock
{
    /**
     * When this shelf was last wiped, or null for never.
     */
    public function erasedAt(User $user, ?ChildProfile $profile): ?CarbonImmutable
    {
        return $this->row($user, $profile)?->erased_at;
    }

    /**
     * Advance the clock to `$at`, unless it is already at or past it.
     *
     * Returns the clock as it stands afterwards, which is what the caller
     * should echo back to the device — the device stores it and censors its
     * own state against the same instant.
     */
    public function record(User $user, ?ChildProfile $profile, CarbonImmutable $at): CarbonImmutable
    {
        return DB::transaction(function () use ($user, $profile, $at): CarbonImmutable {
            $row = $this->row($user, $profile, lock: true);

            if ($row === null) {
                return $this->create($user, $profile, $at)->erased_at;
            }

            if ($row->erased_at->greaterThanOrEqualTo($at)) {
                return $row->erased_at;
            }

            $row->erased_at = $at;
            $row->save();

            return $row->erased_at;
        });
    }

    private function row(User $user, ?ChildProfile $profile, bool $lock = false): ?ShelfErasure
    {
        $query = ShelfErasure::query()
            ->where('user_id', $user->id)
            ->forProfile($profile);

        if ($lock) {
            $query->lockForUpdate();
        }

        return $query->first();
    }

    private function create(User $user, ?ChildProfile $profile, CarbonImmutable $at): ShelfErasure
    {
        $row = new ShelfErasure;
        $row->user_id = $user->id;
        $row->child_profile_id = $profile?->id;
        $row->erased_at = $at;

        try {
            $row->save();
        } catch (QueryException $e) {
            // Two grown-ups pressing the button on two screens at the same
            // instant. The unique index is the arbiter; whoever lost the race
            // reads the row the winner made and re-applies its own instant to
            // it, which is idempotent either way round.
            $existing = $this->row($user, $profile);

            if ($existing === null) {
                throw $e;
            }

            if ($existing->erased_at->lessThan($at)) {
                $existing->erased_at = $at;
                $existing->save();
            }

            return $existing;
        }

        return $row;
    }
}
