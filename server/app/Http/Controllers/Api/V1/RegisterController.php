<?php

namespace App\Http\Controllers\Api\V1;

use App\Actions\Accounts\RegisterParent;
use App\Http\Controllers\Controller;
use App\Http\Requests\Auth\RegisterRequest;
use App\Http\Resources\UserResource;
use Illuminate\Http\JsonResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * `POST /api/v1/auth/register` (DLC_SERVER.md §11).
 *
 * Registering does not sign you in — the client follows up with
 * `POST /auth/token` for a device-scoped token. Keeping the two apart means
 * there is exactly one code path that mints tokens.
 */
class RegisterController extends Controller
{
    public function __invoke(RegisterRequest $request, RegisterParent $register): JsonResponse
    {
        $user = $register->handle(
            email: $request->string('email')->toString(),
            password: $request->string('password')->toString(),
        );

        return response()->json(
            ['user' => new UserResource($user)],
            Response::HTTP_CREATED,
        );
    }
}
