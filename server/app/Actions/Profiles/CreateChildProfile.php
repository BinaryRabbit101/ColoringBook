<?php

namespace App\Actions\Profiles;

use App\Models\ChildProfile;
use App\Models\User;

/**
 * Add a child to the account. Shared by the API (`POST /api/v1/profiles`) and
 * the parent dashboard, so the two can never drift apart.
 */
class CreateChildProfile
{
    /**
     * @param  array{nickname: string, avatar_index?: int, default_mode?: string}  $attributes
     */
    public function handle(User $user, array $attributes): ChildProfile
    {
        $profile = new ChildProfile;

        $profile->fill($attributes);
        $profile->nickname = trim($attributes['nickname']);
        $profile->user()->associate($user);
        $profile->save();

        return $profile;
    }
}
