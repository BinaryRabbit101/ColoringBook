<?php

namespace App\Http\Controllers\Settings;

use App\Actions\Accounts\DeleteAccount;
use App\Http\Controllers\Controller;
use App\Http\Requests\Settings\ProfileDeleteRequest;
use App\Http\Requests\Settings\ProfileUpdateRequest;
use App\Models\User;
use Illuminate\Contracts\Auth\MustVerifyEmail;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Inertia\Inertia;
use Inertia\Response;
use Symfony\Component\HttpFoundation\Response as HttpResponse;

class ProfileController extends Controller
{
    /**
     * Show the user's profile settings page.
     */
    public function edit(Request $request): Response
    {
        return Inertia::render('settings/Profile', [
            'mustVerifyEmail' => $request->user() instanceof MustVerifyEmail,
            'status' => $request->session()->get('status'),
        ]);
    }

    /**
     * Update the user's profile information.
     */
    public function update(ProfileUpdateRequest $request): RedirectResponse
    {
        $request->user()->fill($request->validated());

        if ($request->user()->isDirty('email')) {
            $request->user()->email_verified_at = null;
        }

        $request->user()->save();

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Profile updated.')]);

        return to_route('profile.edit');
    }

    /**
     * Delete the account — for real, and everything hanging off it.
     *
     * `ProfileDeleteRequest` re-confirms the password first (DLC_SERVER.md
     * §4.1: self-serve, one button, and an actual delete rather than a
     * `deleted_at`).
     */
    public function destroy(ProfileDeleteRequest $request, DeleteAccount $delete): RedirectResponse
    {
        $user = $request->user();

        abort_unless($user instanceof User, HttpResponse::HTTP_UNAUTHORIZED);

        Auth::logout();

        $delete->handle($user);

        $request->session()->invalidate();
        $request->session()->regenerateToken();

        return redirect('/');
    }
}
