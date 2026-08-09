<?php

namespace App\Actions\Devices;

use App\Actions\Accounts\IssuedDeviceToken;
use App\Exceptions\ApiException;
use App\Models\Device;
use App\Services\DeviceTokens;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Symfony\Component\HttpFoundation\Response;

/**
 * `POST /api/v1/device/register` — the anonymous tier (BL-52,
 * DLC_SERVER.md §4.3).
 *
 * Find-or-create the `user_id IS NULL` row for a `device_uid` and hand it a
 * Sanctum token carrying `entitlements:read` + `packs:download` and nothing
 * else. No email, no password, no PII: the identifier exists so a device can
 * prove it already bought a pack, which is squarely COPPA's "support for
 * internal operations".
 *
 * Three rules worth stating, because each is a decision:
 *
 *  - **Only ever the anonymous row.** A `device_uid` already linked to an
 *    account is invisible here. Knowing somebody's uid therefore earns an
 *    attacker a fresh, empty anonymous identity — not that household's
 *    entitlements.
 *  - **Re-registering rotates.** The old anonymous tokens for that device are
 *    deleted before the new one is minted, so a uid never accumulates
 *    credentials and a lost tablet's token dies the next time the real one
 *    registers. The *entitlements* are untouched: the row survives, only its
 *    tokens turn over.
 *  - **The device row is the tokenable.** A linked device's token hangs off the
 *    user and is *named* after the uid; an anonymous one has no user to hang
 *    off, so it is minted on the device itself. Both keep the name, so both
 *    revoke the same way.
 */
class RegisterAnonymousDevice
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

            // Rotate: one live token per anonymous device, same rule as a
            // linked one.
            $device->tokens()->delete();

            $expiresAt = $this->tokens->expiresAt();
            $abilities = $this->tokens->anonymousAbilities();

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
     * The unique index is `(coalesce(user_id, 0), device_uid)`, so two tablets
     * registering the same uid in the same instant is a losable race — and an
     * ordinary one, since a reinstall retries. Losing it means the row already
     * exists, which is the answer we wanted; only a genuinely unresolvable
     * write becomes `DEVICE_REGISTRATION_FAILED`.
     */
    private function findOrCreate(string $deviceUid, ?string $deviceName, ?string $platform): Device
    {
        $device = Device::query()->anonymous()->where('device_uid', $deviceUid)->first() ?? new Device;

        $device->user_id = null;
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
            $existing = Device::query()->anonymous()->where('device_uid', $deviceUid)->first();

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
