<?php

namespace App\Actions\Profiles;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use Illuminate\Support\Facades\DB;

/**
 * Remove a child from the account.
 *
 * A hard delete, like everything else in this schema. `book_progress` hangs
 * off `child_profile_id` with `cascadeOnDelete`, so removing a profile takes
 * that child's colouring with it — which is exactly what a parent pressing
 * "remove" expects. It is deleted explicitly as well, for the same reason
 * `DeleteAccount` does: so the sweep is still correct on a connection with
 * foreign keys switched off. WP4 sweeps that child's paint blobs here too.
 */
class DeleteChildProfile
{
    public function handle(ChildProfile $profile): void
    {
        DB::transaction(function () use ($profile): void {
            BookProgress::query()->where('child_profile_id', $profile->id)->delete();

            $profile->delete();
        });
    }
}
