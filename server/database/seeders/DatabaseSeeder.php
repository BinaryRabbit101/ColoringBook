<?php

namespace Database\Seeders;

use App\Models\User;
use Illuminate\Database\Seeder;

class DatabaseSeeder extends Seeder
{
    /**
     * Seed the application's database.
     *
     * `users` holds operators only — there is no registration route, so this
     * (or `php artisan tinker`) is how the first one comes into being.
     *
     * No `WithoutModelEvents` here, deliberately: the public ULID is minted in
     * the model's `creating` hook, and muting events would try to insert a row
     * with a null one.
     */
    public function run(): void
    {
        User::factory()->admin()->create([
            'name' => 'Operator',
            'email' => 'admin@example.com',
        ]);
    }
}
