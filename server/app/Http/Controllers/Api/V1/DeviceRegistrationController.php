<?php

namespace App\Http\Controllers\Api\V1;

use App\Actions\Devices\RegisterDevice;
use App\Http\Controllers\Controller;
use App\Http\Requests\Devices\RegisterDeviceRequest;
use Illuminate\Http\JsonResponse;

/**
 * `POST /api/v1/device/register` (DLC_SERVER.md §4.3, §11).
 *
 * **The only way a client ever authenticates.** No email, no password, no
 * account: the device presents the `device_uid` it minted at install and gets
 * back the credential it uses for the catalog, its entitlements and every
 * download.
 *
 * The contract, pinned — the game client codes against exactly this:
 *
 *     {device_uid, device_name, platform}
 *       → {token, abilities, expires_at, device: {ulid}}
 *
 * `abilities` are worth reading rather than assuming: `entitlements:read` and
 * `packs:download`, and nothing else. Find-or-create semantics mean a 401 is
 * recovered by calling this again with the same uid — the same device row, the
 * same entitlements, a fresh token.
 */
class DeviceRegistrationController extends Controller
{
    public function __invoke(RegisterDeviceRequest $request, RegisterDevice $register): JsonResponse
    {
        $issued = $register->handle(
            deviceUid: $request->string('device_uid')->toString(),
            deviceName: $request->input('device_name') === null ? null : $request->string('device_name')->toString(),
            platform: $request->input('platform') === null ? null : $request->string('platform')->toString(),
        );

        return response()->json([
            'token' => $issued->plainTextToken,
            'abilities' => $issued->abilities,
            'expires_at' => $issued->expiresAt->toIso8601String(),
            'device' => ['ulid' => $issued->device->ulid],
        ]);
    }
}
