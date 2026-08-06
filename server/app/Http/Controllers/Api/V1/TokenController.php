<?php

namespace App\Http\Controllers\Api\V1;

use App\Actions\Accounts\IssueDeviceToken;
use App\Actions\Accounts\RefreshDeviceToken;
use App\Exceptions\ApiException;
use App\Http\Controllers\Controller;
use App\Http\Requests\Auth\IssueTokenRequest;
use App\Http\Resources\UserResource;
use App\Models\User;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Hash;
use Laravel\Sanctum\PersonalAccessToken;
use Symfony\Component\HttpFoundation\Response;

/**
 * The device token's whole life: issue, slide, revoke (DLC_SERVER.md §4.2).
 */
class TokenController extends Controller
{
    /**
     * `POST /api/v1/auth/token` — sign this device in.
     *
     * Re-signing in on a device that already has a token replaces it, so a
     * device never accumulates credentials.
     */
    public function store(IssueTokenRequest $request, IssueDeviceToken $issue): JsonResponse
    {
        $user = User::query()
            ->where('email', $request->string('email')->toString())
            ->first();

        // One failure mode, one message: never reveal which half was wrong,
        // and always spend the hash so timing doesn't either.
        if ($user === null || ! Hash::check($request->string('password')->toString(), $user->password)) {
            throw ApiException::invalidCredentials();
        }

        $issued = $issue->handle(
            user: $user,
            deviceUid: $request->string('device_uid')->toString(),
            deviceName: $request->input('device_name') === null ? null : $request->string('device_name')->toString(),
            platform: $request->input('platform') === null ? null : $request->string('platform')->toString(),
        );

        return response()->json([
            'token' => $issued->plainTextToken,
            'abilities' => $issued->abilities,
            'expires_at' => $issued->expiresAt->toIso8601String(),
            'user' => new UserResource($user),
        ]);
    }

    /**
     * `POST /api/v1/auth/refresh` — push the 90-day window out from now.
     */
    public function refresh(Request $request, RefreshDeviceToken $refresh): JsonResponse
    {
        $user = $this->tokenUser($request);
        $token = $this->currentToken($user);

        $expiresAt = $refresh->handle($user, $token);

        return response()->json([
            'expires_at' => $expiresAt->toIso8601String(),
        ]);
    }

    /**
     * `DELETE /api/v1/auth/token` — sign this device out.
     *
     * Only ever this device: a game token can't reach into the household and
     * sign out the other tablet. That lives in the dashboard.
     */
    public function destroy(Request $request): Response
    {
        $user = $this->tokenUser($request);

        $this->currentToken($user)->delete();

        return response()->noContent();
    }

    private function tokenUser(Request $request): User
    {
        $user = $request->user();

        abort_unless($user instanceof User, Response::HTTP_UNAUTHORIZED);

        return $user;
    }

    private function currentToken(User $user): PersonalAccessToken
    {
        $token = $user->currentAccessToken();

        // A session-backed (dashboard) caller has no personal access token to
        // refresh or revoke; these endpoints are for the game client only.
        abort_unless($token instanceof PersonalAccessToken, Response::HTTP_UNAUTHORIZED);

        return $token;
    }
}
