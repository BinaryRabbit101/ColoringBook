<?php

namespace App\Http\Requests\Auth;

use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;

/**
 * `POST /api/v1/auth/token` — sign in one device.
 *
 * `device_uid` is a ULID the client mints once and keeps in `user://` forever;
 * it names the Sanctum token, so it is what makes per-device revocation
 * possible (DLC_SERVER.md §4.2). `device_name` and `platform` exist purely so
 * the parent recognises the row in the dashboard.
 */
class IssueTokenRequest extends FormRequest
{
    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'email' => ['required', 'string', 'email', 'max:255'],
            'password' => ['required', 'string'],
            'device_uid' => ['required', 'string', 'min:8', 'max:64'],
            'device_name' => ['nullable', 'string', 'max:120'],
            'platform' => ['nullable', 'string', 'max:40'],
        ];
    }
}
