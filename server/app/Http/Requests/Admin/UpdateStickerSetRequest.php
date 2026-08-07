<?php

namespace App\Http\Requests\Admin;

use Illuminate\Foundation\Http\FormRequest;

/**
 * `PATCH /admin/sticker-sets/{set_uid}` — retitle, or move the set in the
 * client's cycle ring (BL-37).
 *
 * `set_uid` is absent by design and cannot be changed: it is what every saved
 * sticker placement on every device names (BL-36's save shape). Renaming a set
 * means a new set.
 */
class UpdateStickerSetRequest extends FormRequest
{
    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        return [
            'title' => ['sometimes', 'required', 'string', 'max:120'],
            'blurb' => ['sometimes', 'nullable', 'string', 'max:500'],
            'sort_order' => ['sometimes', 'integer', 'min:0', 'max:9999'],
            'is_free' => ['sometimes', 'boolean'],
        ];
    }
}
