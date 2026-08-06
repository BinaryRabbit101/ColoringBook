<?php

namespace App\Http\Controllers\Api\V1;

use App\Actions\Profiles\CreateChildProfile;
use App\Actions\Profiles\DeleteChildProfile;
use App\Actions\Profiles\UpdateChildProfile;
use App\Http\Controllers\Controller;
use App\Http\Requests\ChildProfiles\StoreChildProfileRequest;
use App\Http\Requests\ChildProfiles\UpdateChildProfileRequest;
use App\Http\Resources\ChildProfileResource;
use App\Models\ChildProfile;
use App\Models\User;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * `/api/v1/profiles` (DLC_SERVER.md §11 "Profiles").
 *
 * Reachable with a game token — a child switching profiles on the tablet is
 * ordinary play, not account administration. What a game token still cannot
 * do is delete the account, change the password or sign out another device;
 * those are dashboard-only, behind a password re-confirmation (§4.2).
 *
 * Every profile is resolved *through the signed-in user*, so one account can
 * never address another's rows: a wrong ULID is a 404, never a 403 that
 * confirms the row exists.
 */
class ChildProfileController extends Controller
{
    public function index(Request $request): JsonResponse
    {
        return response()->json([
            'profiles' => ChildProfileResource::collection(
                $this->user($request)->childProfiles()->get(),
            ),
        ]);
    }

    public function store(StoreChildProfileRequest $request, CreateChildProfile $create): JsonResponse
    {
        /** @var array{nickname: string, avatar_index?: int, default_mode?: string} $attributes */
        $attributes = $request->validated();

        $profile = $create->handle($this->user($request), $attributes);

        return response()->json(
            ['profile' => new ChildProfileResource($profile)],
            Response::HTTP_CREATED,
        );
    }

    public function update(
        UpdateChildProfileRequest $request,
        string $profile,
        UpdateChildProfile $update,
    ): JsonResponse {
        /** @var array{nickname?: string, avatar_index?: int, default_mode?: string} $attributes */
        $attributes = $request->validated();

        $updated = $update->handle($this->find($request, $profile), $attributes);

        return response()->json(['profile' => new ChildProfileResource($updated)]);
    }

    public function destroy(Request $request, string $profile, DeleteChildProfile $delete): Response
    {
        $delete->handle($this->find($request, $profile));

        return response()->noContent();
    }

    private function find(Request $request, string $ulid): ChildProfile
    {
        return $this->user($request)
            ->childProfiles()
            ->where('ulid', $ulid)
            ->firstOrFail();
    }

    private function user(Request $request): User
    {
        $user = $request->user();

        abort_unless($user instanceof User, Response::HTTP_UNAUTHORIZED);

        return $user;
    }
}
