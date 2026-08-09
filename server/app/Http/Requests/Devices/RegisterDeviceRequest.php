<?php

namespace App\Http\Requests\Devices;

use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;

/**
 * `POST /api/v1/device/register` — the anonymous tier (BL-52,
 * DLC_SERVER.md §4.3).
 *
 * The same three fields `POST /auth/token` already carries, minus the
 * credentials, and bounded identically so a uid means the same thing on both
 * routes. `device_name` and `platform` exist purely so a parent recognises the
 * row in the dashboard *after* they sign in and the device is adopted.
 *
 * Nothing here is PII, and nothing here may be: a `device_uid` is a ULID the
 * client minted for itself.
 */
class RegisterDeviceRequest extends FormRequest
{
    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'device_uid' => ['required', 'string', 'min:8', 'max:64'],
            'device_name' => ['nullable', 'string', 'max:120'],
            'platform' => ['nullable', 'string', 'max:40'],
        ];
    }
}
