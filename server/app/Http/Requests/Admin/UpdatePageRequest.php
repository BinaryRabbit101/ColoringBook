<?php

namespace App\Http\Requests\Admin;

use Illuminate\Foundation\Http\FormRequest;

/**
 * `PATCH /admin/books/{book_uid}/pages/{index}` — retitle, reorder, or replace
 * art (BL-24, §10.3).
 *
 * Every field is `sometimes`: this endpoint carries four unrelated edits and a
 * form that submits one of them must not be read as clearing the other three.
 *
 * `remove_mask` is a separate boolean rather than "send an empty mask", because
 * an absent file field and a deliberately cleared one look identical in a
 * multipart body — and the difference between them is whether the page keeps
 * its mapping source.
 */
class UpdatePageRequest extends FormRequest
{
    use PageTuningRules;

    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        $max = (int) config('coloringbook.authoring.max_image_kb');

        return [
            'title' => ['sometimes', 'nullable', 'string', 'max:120'],
            'page_index' => ['sometimes', 'integer', 'min:0', 'max:9999'],

            'display' => ['sometimes', 'file', 'mimes:png', 'max:'.$max],
            'display_asset_ulid' => ['sometimes', 'string', 'exists:assets,ulid'],

            'mask' => ['sometimes', 'file', 'mimes:png', 'max:'.$max],
            'mask_asset_ulid' => ['sometimes', 'string', 'exists:assets,ulid'],
            'remove_mask' => ['sometimes', 'boolean'],

            ...$this->tuningRules(),
        ];
    }

    /**
     * @return array<string, string>
     */
    public function attributes(): array
    {
        return [
            'display' => __('detail image'),
            'mask' => __('masking image'),
        ];
    }
}
