<?php

namespace App\Http\Controllers\Api\V1;

use App\Actions\Devices\RegisterAnonymousDevice;
use App\Http\Controllers\Controller;
use App\Http\Requests\Devices\RegisterDeviceRequest;
use Illuminate\Http\JsonResponse;

/**
 * `POST /api/v1/device/register` (BL-52, DLC_SERVER.md §4.3, §11).
 *
 * The smaller of the two identities: an anonymous device, no account, no PII.
 * It answers the same envelope `POST /auth/token` does — `{token, abilities,
 * expires_at, …}` — with a `device` block in place of a `user`, so a client
 * stores both credentials through one code path.
 *
 * The `abilities` in the response are worth reading rather than assuming: they
 * are `entitlements:read` + `packs:download` and **never** `save:sync`. A
 * client that keys its sync queue off the account token (as the design asks)
 * can therefore prove locally that it will never try to upload with this one.
 */
class DeviceRegistrationController extends Controller
{
    public function __invoke(RegisterDeviceRequest $request, RegisterAnonymousDevice $register): JsonResponse
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
