<?php

namespace App\Actions\Profiles;

use App\Models\ChildProfile;

/**
 * Rename a child, move their avatar, change their default mode. A partial
 * update: whatever the caller left out stays as it was.
 */
class UpdateChildProfile
{
    /**
     * @param  array{nickname?: string, avatar_index?: int, default_mode?: string}  $attributes
     */
    public function handle(ChildProfile $profile, array $attributes): ChildProfile
    {
        $profile->fill($attributes);

        if (array_key_exists('nickname', $attributes)) {
            $profile->nickname = trim($attributes['nickname']);
        }

        $profile->save();

        return $profile;
    }
}
