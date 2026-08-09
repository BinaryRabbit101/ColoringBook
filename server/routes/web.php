<?php

use Illuminate\Support\Facades\Route;

Route::inertia('/', 'Welcome')->name('home');

/*
 * There is no registration and no email verification: the only rows in `users`
 * belong to the operator who publishes packs, and they are created with a
 * seeder or a shell. Everything below `auth` is that person's dashboard.
 */
Route::middleware(['auth'])->group(function () {
    Route::inertia('dashboard', 'Dashboard')->name('dashboard');
});

require __DIR__.'/settings.php';
require __DIR__.'/admin.php';
