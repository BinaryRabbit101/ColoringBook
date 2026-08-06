<?php

namespace App\Actions\Accounts;

use App\Models\Device;
use App\Models\User;

/**
 * "Sign this device out" from the parent dashboard.
 *
 * Deleting the tokens named after the device_uid is the whole mechanism: the
 * next API call from that install 401s and the game drops into offline mode
 * silently — never a modal in a child's face (DLC_SERVER.md §4.2).
 *
 * The device row survives. It is the record that the install exists, with its
 * last-seen history intact, and it lights up again the moment someone signs
 * in on it.
 */
class RevokeDevice
{
    /**
     * @return int the number of tokens revoked
     */
    public function handle(User $user, Device $device): int
    {
        return $user->tokens()->where('name', $device->device_uid)->delete();
    }
}
