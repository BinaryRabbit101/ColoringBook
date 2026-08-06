<?php

namespace App\Actions\Profiles;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\PaintLayer;
use App\Services\PaintStorage;
use Illuminate\Support\Facades\DB;

/**
 * Remove a child from the account.
 *
 * A hard delete, like everything else in this schema. `book_progress` hangs
 * off `child_profile_id` with `cascadeOnDelete` and `paint_layers` off
 * `book_progress_id`, so removing a profile takes that child's colouring *and*
 * their pictures with it — which is exactly what a parent pressing "remove"
 * expects. Both are deleted explicitly as well, for the same reason
 * `DeleteAccount` does: so the sweep is still correct on a connection with
 * foreign keys switched off.
 *
 * The blobs go after the commit, and only from `paint/<user>/<profile>/` —
 * the rest of the household's pictures are untouched.
 */
class DeleteChildProfile
{
    public function __construct(private readonly PaintStorage $paint) {}

    public function handle(ChildProfile $profile): void
    {
        DB::transaction(function () use ($profile): void {
            PaintLayer::query()
                ->whereIn(
                    'book_progress_id',
                    BookProgress::query()->select('id')->where('child_profile_id', $profile->id),
                )
                ->delete();

            BookProgress::query()->where('child_profile_id', $profile->id)->delete();

            $profile->delete();
        });

        $this->paint->forgetProfile($profile);
    }
}
