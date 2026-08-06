<?php

namespace App\Http\Controllers\Settings;

use App\Actions\Accounts\RevokeDevice;
use App\Http\Controllers\Controller;
use App\Http\Resources\DeviceResource;
use App\Models\Device;
use App\Models\User;
use App\Services\DeviceTokens;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Inertia\Inertia;
use Inertia\Response as InertiaResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * The parent dashboard's devices page: what has signed in, when it was last
 * seen, and a button to sign one of them out (DLC_SERVER.md §4.2).
 *
 * Revocation is deliberately dashboard-only. A stolen `user://auth.json` must
 * not be able to lock the household out of its own account.
 */
class DeviceController extends Controller
{
    public function __construct(private readonly DeviceTokens $tokens) {}

    public function index(Request $request): InertiaResponse
    {
        return Inertia::render('settings/Devices', [
            'devices' => DeviceResource::collection(
                $this->tokens->devicesFor($this->user($request)),
            ),
        ]);
    }

    public function destroy(Request $request, string $device, RevokeDevice $revoke): RedirectResponse
    {
        $user = $this->user($request);

        $model = Device::query()
            ->where('user_id', $user->id)
            ->where('ulid', $device)
            ->firstOrFail();

        $revoke->handle($user, $model);

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Device signed out.')]);

        return to_route('devices.edit');
    }

    private function user(Request $request): User
    {
        $user = $request->user();

        abort_unless($user instanceof User, Response::HTTP_UNAUTHORIZED);

        return $user;
    }
}
