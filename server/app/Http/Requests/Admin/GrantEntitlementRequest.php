<?php

namespace App\Http\Requests\Admin;

use App\Models\Entitlement;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

/**
 * `POST /admin/entitlements` — a promo or gift claim, by `device_uid`.
 *
 * `device_uid` is deliberately not validated with `exists:devices`: whether a
 * uid belongs to a registered device is the action's answer
 * (`DEVICE_NOT_FOUND`), and folding it into a 422 field bag would make "no such
 * device" look like a typo in the form.
 *
 * `purchase` and `free` are not offered. A purchase is written by the store
 * verification path and a free claim writes itself on first download; letting
 * an operator forge either would make the `source` column stop meaning
 * anything.
 */
class GrantEntitlementRequest extends FormRequest
{
    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        return [
            'device_uid' => ['required', 'string', 'max:64'],
            'pack_slug' => ['required', 'string', 'max:64'],
            'source' => ['sometimes', 'string', Rule::in([
                Entitlement::SOURCE_PROMO,
                Entitlement::SOURCE_GIFT,
                Entitlement::SOURCE_ADMIN,
            ])],
        ];
    }
}
