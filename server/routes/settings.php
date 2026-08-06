<?php

use App\Http\Controllers\Settings\ChildProfileController;
use App\Http\Controllers\Settings\DeviceController;
use App\Http\Controllers\Settings\ProfileController;
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
