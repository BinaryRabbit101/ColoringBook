<?php

namespace App\Http\Requests\Devices;

use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;

/**
 * `POST /api/v1/device/register` — the only client identity (DLC_SERVER.md
 * §4.3).
 *
 * Three fields; the last two are optional labels, so the operator has something
 * readable beside a device's entitlements when a support question arrives.
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
