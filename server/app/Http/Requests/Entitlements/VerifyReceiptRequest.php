<?php

namespace App\Http\Requests\Entitlements;

use App\Services\Stores\StoreReceipts;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

/**
 * `POST /api/v1/entitlements/verify` — `{platform, purchase_token, sku}`
 * (DLC_SERVER.md §9).
 *
 * `platform` is validated against `coloringbook.stores.sku_columns`, so a
 * platform this build has never heard of is a 422 with a field error, while a
 * known platform with no verifier configured is the 503 `STORE_UNAVAILABLE`
 * the client should retry. Two different problems, two different answers.
 *
 * The pack is resolved from the SKU and nothing else — there is deliberately no
 * `pack_slug` field. A body that named both would let a client pair a valid
 * receipt with a pack of its choosing.
 */
class VerifyReceiptRequest extends FormRequest
{
    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'platform' => ['required', 'string', Rule::in(app(StoreReceipts::class)->platforms())],
            // Play's purchase tokens run to a few hundred characters; App Store
            // receipts are far longer, so the ceiling is generous rather than
            // tight. It is a guard rail, not a format check — the verifier is
            // what decides whether the string means anything.
            'purchase_token' => ['required', 'string', 'min:8', 'max:8192'],
            'sku' => ['required', 'string', 'max:191'],
        ];
    }
}
