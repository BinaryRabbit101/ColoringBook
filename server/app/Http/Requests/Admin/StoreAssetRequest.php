<?php

namespace App\Http\Requests\Admin;

use App\Models\Asset;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

/**
 * `POST /admin/assets`. Authorisation is the route's `EnsureAdmin`, so this
 * only decides what a well-formed upload looks like.
 *
 * `kind` is required rather than sniffed: the same PNG is a `display` on one
 * page and a `cover` on another, and only the operator's build script knows
 * which role it is uploading for.
 */
class StoreAssetRequest extends FormRequest
{
    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        return [
            'file' => ['required', 'file', 'max:'.(int) config('coloringbook.admin.max_upload_kb')],
            'kind' => ['required', 'string', Rule::in(Asset::KINDS)],
        ];
    }
}
