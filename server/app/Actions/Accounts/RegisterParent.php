<?php

namespace App\Actions\Accounts;

use App\Models\User;

/**
 * Create a parent account from the game's sign-up screen.
 *
 * Email and password are the entire PII footprint: no name, no date of birth,
 * nothing about the child (DLC_SERVER.md §4.1). The guardian confirmation is
 * validated at the request boundary and deliberately not stored — it is a
 * statement made at a moment, not an attribute of the person.
 */
class RegisterParent
{
    public function handle(string $email, string $password): User
    {
        return User::create([
            'email' => $email,
            'password' => $password,
        ]);
    }
}
