<?php

namespace App\Actions\Fortify;

use App\Concerns\PasswordValidationRules;
use App\Concerns\ProfileValidationRules;
use App\Models\User;
use Illuminate\Support\Facades\Validator;
use Laravel\Fortify\Contracts\CreatesNewUsers;

class CreateNewUser implements CreatesNewUsers
{
    use PasswordValidationRules, ProfileValidationRules;

    /**
     * Validate and create a newly registered user.
     *
     * The guardian confirmation is not optional: an account here belongs to a
     * grown-up (DLC_SERVER.md §4.1). It is checked and then deliberately not
     * stored — a promise made at a moment, not an attribute of a person. The
     * API register endpoint asks for exactly the same thing.
     *
     * @param  array<string, string>  $input
     */
    public function create(array $input): User
    {
        Validator::make($input, [
            ...$this->profileRules(),
            'password' => $this->passwordRules(),
            'is_guardian' => ['required', 'accepted'],
        ], [
            'is_guardian.required' => __('Please confirm you are the parent or guardian.'),
            'is_guardian.accepted' => __('Please confirm you are the parent or guardian.'),
        ])->validate();

        return User::create([
            'name' => $input['name'],
            'email' => $input['email'],
            'password' => $input['password'],
        ]);
    }
}
