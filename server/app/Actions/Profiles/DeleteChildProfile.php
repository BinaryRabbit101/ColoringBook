<?php

namespace App\Actions\Profiles;

use App\Models\ChildProfile;

/**
 * Remove a child from the account.
 *
 * A hard delete, like everything else in this schema. Later work packages
 * hang `book_progress` (WP2) and paint blobs (WP4) off `child_profile_id`
 * with `cascadeOnDelete`, so removing a profile takes that child's colouring
 * with it — which is exactly what a parent pressing "remove" expects.
 */
class DeleteChildProfile
{
    public function handle(ChildProfile $profile): void
    {
        $profile->delete();
    }
}
