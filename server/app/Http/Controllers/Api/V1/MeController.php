<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Http\Resources\ChildProfileResource;
use App\Http\Resources\DeviceResource;
use App\Http\Resources\UserResource;
use App\Models\User;
use App\Services\DeviceTokens;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * `GET /api/v1/me` — everything the client needs to draw its account screen
 * in one round trip: the parent, the children, the household's devices
 * (DLC_SERVER.md §11).
 */
class MeController extends Controller
{
    public function __construct(private readonly DeviceTokens $tokens) {}

    public function __invoke(Request $request): JsonResponse
    {
        $user = $request->user();

        abort_unless($user instanceof User, Response::HTTP_UNAUTHORIZED);

        return response()->json([
            'user' => new UserResource($user),
            'profiles' => ChildProfileResource::collection($user->childProfiles()->get()),
            'devices' => DeviceResource::collection($this->tokens->devicesFor($user)),
        ]);
    }
}
