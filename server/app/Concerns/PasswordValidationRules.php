<?php

namespace App\Concerns;

use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Validation\Rules\Password;

trait PasswordValidationRules
{
    /**
     * Get the validation rules used to validate passwords.
     *
     * The game client posts a single `password` field — there is no second
     * "confirm" box on a tablet keyboard — so the API register endpoint asks
     * for the same strength without the confirmation.
     *
     * @return array<int, Password|ValidationRule|array<mixed>|string>
     */
    protected function passwordRules(bool $confirmed = true): array
    {
        $rules = ['required', 'string', Password::default()];

        return $confirmed ? [...$rules, 'confirmed'] : $rules;
    }

    /**
     * Get the validation rules used to validate the current password.
     *
     * @return array<int, Password|ValidationRule|array<mixed>|string>
     */
    protected function currentPasswordRules(): array
    {
        return ['required', 'string', 'current_password'];
    }
}
