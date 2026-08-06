<?php

namespace App\Http\Controllers\Settings;

use App\Actions\Profiles\CreateChildProfile;
use App\Actions\Profiles\DeleteChildProfile;
use App\Actions\Profiles\UpdateChildProfile;
use App\Http\Controllers\Controller;
use App\Http\Requests\ChildProfiles\StoreChildProfileRequest;
use App\Http\Requests\ChildProfiles\UpdateChildProfileRequest;
use App\Http\Resources\ChildProfileResource;
use App\Models\ChildProfile;
use App\Models\User;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Inertia\Inertia;
use Inertia\Response as InertiaResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * The parent dashboard's children page — session auth, not tokens.
 *
 * It reuses the same actions and the same FormRequests as the API, so a
 * nickname length or an avatar bound can never mean two different things
 * depending on which door you came through.
 */
class ChildProfileController extends Controller
{
    public function index(Request $request): InertiaResponse
    {
        return Inertia::render('settings/Profiles', [
            'profiles' => ChildProfileResource::collection(
                $this->user($request)->childProfiles()->get(),
            ),
            'avatarCount' => (int) config('coloringbook.profiles.avatar_count'),
            'nicknameMax' => (int) config('coloringbook.profiles.nickname_max'),
            'modes' => config('coloringbook.profiles.modes'),
        ]);
    }

    public function store(StoreChildProfileRequest $request, CreateChildProfile $create): RedirectResponse
    {
        /** @var array{nickname: string, avatar_index?: int, default_mode?: string} $attributes */
        $attributes = $request->validated();

        $create->handle($this->user($request), $attributes);

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Profile added.')]);

        return to_route('child-profiles.edit');
    }

    public function update(UpdateChildProfileRequest $request, string $profile, UpdateChildProfile $update): RedirectResponse
    {
        /** @var array{nickname?: string, avatar_index?: int, default_mode?: string} $attributes */
        $attributes = $request->validated();

        $update->handle($this->find($request, $profile), $attributes);

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Profile updated.')]);

        return to_route('child-profiles.edit');
    }

    public function destroy(Request $request, string $profile, DeleteChildProfile $delete): RedirectResponse
    {
        $delete->handle($this->find($request, $profile));

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Profile removed.')]);

        return to_route('child-profiles.edit');
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
