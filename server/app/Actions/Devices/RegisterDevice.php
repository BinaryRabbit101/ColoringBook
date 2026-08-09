<?php

namespace App\Actions\Devices;

use App\Exceptions\ApiException;
use App\Models\Device;
use App\Services\DeviceTokens;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Symfony\Component\HttpFoundation\Response;

/**
 * `POST /api/v1/device/register` — **the only client identity there is**
 * (DLC_SERVER.md §4.3).
 *
 * Find-or-create the row for a `device_uid` and hand it a Sanctum token
 * carrying `entitlements:read` + `packs:download` and nothing else. No email,
 * no password, no PII: the identifier exists so a device can prove it already
 * bought a pack, which is squarely COPPA's "support for internal operations".
 *
 * Three rules worth stating, because each is a decision:
 *
 *  - **Find-or-create, so re-auth is idempotent.** There is no refresh route: a
 *    client that gets a 401 simply calls this again and keeps its entitlements,
 *    because the row is looked up by the uid it has held since install.
 *  - **Re-registering rotates.** The device's old tokens are deleted before the
 *    new one is minted, so a uid never accumulates credentials and a lost
 *    tablet's token dies the next time the real one registers. The
 *    *entitlements* are untouched: the row survives, only its tokens turn over.
 *  - **The device row is the tokenable.** There is no account for a token to
 *    hang off, so it is minted on the device itself and *named* after the uid,
 *    which is how a single install is revoked.
 */
class RegisterDevice
{
    public function __construct(private readonly DeviceTokens $tokens) {}

    public function handle(
        string $deviceUid,
        ?string $deviceName = null,
        ?string $platform = null,
    ): IssuedDeviceToken {
        return DB::transaction(function () use ($deviceUid, $deviceName, $platform): IssuedDeviceToken {
            $device = $this->findOrCreate($deviceUid, $deviceName, $platform);

            $this->tokens->touchDevice($device, force: true);

            // Rotate: one live token per device.
            $device->tokens()->delete();

            $expiresAt = $this->tokens->expiresAt();
            $abilities = $this->tokens->abilities();

            $token = $device->createToken($deviceUid, $abilities, $expiresAt);

            return new IssuedDeviceToken(
                plainTextToken: $token->plainTextToken,
                abilities: $abilities,
                expiresAt: $expiresAt,
                device: $device,
            );
        });
    }

    /**
     * `device_uid` is unique, so two tablets registering the same uid in the
     * same instant is a losable race — and an ordinary one, since a reinstall
     * retries. Losing it means the row already exists, which is the answer we
     * wanted; only a genuinely unresolvable write becomes
     * `DEVICE_REGISTRATION_FAILED`.
     */
    private function findOrCreate(string $deviceUid, ?string $deviceName, ?string $platform): Device
    {
        $device = Device::query()->where('device_uid', $deviceUid)->first() ?? new Device;

        $device->device_uid = $deviceUid;

        // Only overwrite what the client actually told us this time.
        if ($deviceName !== null) {
            $device->device_name = $deviceName;
        }

        if ($platform !== null) {
            $device->platform = $platform;
        }

        try {
            $device->save();
        } catch (QueryException $e) {
            $existing = Device::query()->where('device_uid', $deviceUid)->first();

            if ($existing === null) {
                throw new ApiException(
                    'DEVICE_REGISTRATION_FAILED',
                    __('This device could not be registered. Please try again.'),
                    Response::HTTP_UNPROCESSABLE_ENTITY,
                    previous: $e,
                );
            }

            return $existing;
        }

        return $device;
    }
}
