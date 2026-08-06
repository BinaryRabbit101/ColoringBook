<?php

namespace App\Http\Requests\Auth;

use App\Concerns\PasswordValidationRules;
use App\Concerns\ProfileValidationRules;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;

/**
 * `POST /api/v1/auth/register` — the game's sign-up screen, behind the client
 * side adult gate.
 *
 * Three fields, and one of them is a promise: `is_guardian` must be present
 * and true. An account here belongs to a grown-up (DLC_SERVER.md §4.1).
 */
class RegisterRequest extends FormRequest
{
    use PasswordValidationRules, ProfileValidationRules;

    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'email' => $this->emailRules(),
            'password' => $this->passwordRules(confirmed: false),
            'is_guardian' => ['required', 'accepted'],
        ];
    }

    /**
     * @return array<string, string>
     */
    public function messages(): array
    {
        return [
            'is_guardian.required' => __('Please confirm you are the parent or guardian.'),
            'is_guardian.accepted' => __('Please confirm you are the parent or guardian.'),
        ];
    }
}
