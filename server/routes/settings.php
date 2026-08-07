<?php

use App\Http\Controllers\Settings\ChildProfileController;
use App\Http\Controllers\Settings\DeviceController;
use App\Http\Controllers\Settings\PaintController;
use App\Http\Controllers\Settings\ProfileController;
use App\Http\Controllers\Settings\ProgressController;
use App\Http\Controllers\Settings\SecurityController;
use Illuminate\Auth\Middleware\RequirePassword;
use Illuminate\Support\Facades\Route;

Route::middleware(['auth'])->group(function () {
    Route::redirect('settings', '/settings/profile');

    Route::get('settings/profile', [ProfileController::class, 'edit'])->name('profile.edit');
    Route::patch('settings/profile', [ProfileController::class, 'update'])->name('profile.update');

    /*
     * The parent dashboard (DLC_SERVER.md §4.1). Session auth, never tokens:
     * a game token can read and edit profiles, but signing another device out
     * happens here and nowhere else.
     *
     * Deliberately not behind `verified` — MAIL_MAILER is `log` for now
     * (SERVER_BUILD_PLAN.md Q11), and a parent locked out of their own device
     * list by an unread verification mail is a support ticket we don't need.
     */
    Route::get('settings/profiles', [ChildProfileController::class, 'index'])->name('child-profiles.edit');
    Route::post('settings/profiles', [ChildProfileController::class, 'store'])->name('child-profiles.store');
    Route::patch('settings/profiles/{profile}', [ChildProfileController::class, 'update'])->name('child-profiles.update');
    Route::delete('settings/profiles/{profile}', [ChildProfileController::class, 'destroy'])->name('child-profiles.destroy');

    Route::get('settings/devices', [DeviceController::class, 'index'])->name('devices.edit');
    Route::delete('settings/devices/{device}', [DeviceController::class, 'destroy'])->name('devices.destroy');

    /*
     * WP4 — "restore the older picture" (DLC_SERVER.md §6.3). When two devices
     * paint the same page, one version loses and is kept for 30 days; this is
     * where a parent gets it back. Never a game route: a child is never shown
     * the choice.
     */
    Route::get('settings/pictures', [PaintController::class, 'index'])->name('pictures.edit');
    Route::post('settings/pictures/{retained}/restore', [PaintController::class, 'restore'])->name('pictures.restore');

    /*
     * BL-18 — "erase everything", where the grown-up already is. The game's
     * own button erases one tablet and then has to argue with the server about
     * it; this erases the thing every tablet pulls from. `{shelf}` is a child's
     * ULID or the literal `account`. Session auth, never a token, for the same
     * reason the pictures page is: a five year old must not be able to reach
     * it, and a game token must not be able to make it.
     */
    Route::get('settings/progress', [ProgressController::class, 'index'])->name('progress.edit');
    Route::delete('settings/progress/{shelf}', [ProgressController::class, 'destroy'])->name('progress.destroy');
});

Route::middleware(['auth', 'verified'])->group(function () {
    Route::delete('settings/profile', [ProfileController::class, 'destroy'])->name('profile.destroy');

    Route::get('settings/security', [SecurityController::class, 'edit'])
        ->middleware(RequirePassword::class)
        ->name('security.edit');

    Route::put('settings/password', [SecurityController::class, 'update'])
        ->middleware('throttle:6,1')
        ->name('user-password.update');

    Route::inertia('settings/appearance', 'settings/Appearance')->name('appearance.edit');
});

Route::get('.well-known/passkey-endpoints', function () {
    return response()->json([
        'enroll' => route('security.edit'),
        'manage' => route('security.edit'),
    ]);
})->name('well-known.passkeys');
