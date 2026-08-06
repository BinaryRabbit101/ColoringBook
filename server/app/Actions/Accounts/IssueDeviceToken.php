<?php

namespace App\Actions\Accounts;

use App\Models\Device;
use App\Models\User;
use App\Services\DeviceTokens;
use Illuminate\Support\Facades\DB;

/**
 * Sign a device in: remember the device, replace its old token, issue a new
 * one (DLC_SERVER.md §4.2).
 *
 * "Replace" is the important half. A device that signs in again — reinstall,
 * password change, expired token — must end up with exactly one live token,
 * so the parent dashboard's device list stays a truthful list of things that
 * can reach the account.
 */
class IssueDeviceToken
{
    public function __construct(private readonly DeviceTokens $tokens) {}

    public function handle(
        User $user,
        string $deviceUid,
        ?string $deviceName = null,
        ?string $platform = null,
    ): IssuedDeviceToken {
        return DB::transaction(function () use ($user, $deviceUid, $deviceName, $platform): IssuedDeviceToken {
            $device = Device::firstOrNew([
                'user_id' => $user->id,
                'device_uid' => $deviceUid,
            ]);

            // Only overwrite what the client actually told us this time.
            if ($deviceName !== null) {
                $device->device_name = $deviceName;
            }

            if ($platform !== null) {
                $device->platform = $platform;
            }

            $device->user_id = $user->id;
            $device->device_uid = $deviceUid;
            $device->save();

            $this->tokens->touchDevice($device, force: true);

            // The token is named after the device — one live token per device.
            $user->tokens()->where('name', $deviceUid)->delete();

            $expiresAt = $this->tokens->expiresAt();
            $abilities = $this->tokens->abilities();

            $token = $user->createToken($deviceUid, $abilities, $expiresAt);

            return new IssuedDeviceToken(
                plainTextToken: $token->plainTextToken,
                abilities: $abilities,
                expiresAt: $expiresAt,
                device: $device,
            );
        });
    }
}
