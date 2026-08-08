<?php

namespace App\Http\Requests\Admin;

use Illuminate\Foundation\Http\FormRequest;

/**
 * `PATCH /admin/books/{book_uid}` — retitle (BL-24, §10.3).
 *
 * `book_uid` is absent by design and cannot be changed: it is the key every
 * saved page on every device hangs off (§6.1). Renaming a book means a new
 * book.
 *
 * BL-38 adds the **cover image**, which arrives the same two ways a page's art
 * does — a multipart file or the ULID of an asset already uploaded to
 * `POST /admin/assets` — and comes off with a separate `remove_cover` boolean,
 * for the reason `remove_mask` exists on a page: an absent file field and a
 * deliberately cleared one look identical in a multipart body.
 *
 * PNG only, like every other artwork upload on this surface.
 */
class UpdateBookRequest extends FormRequest
{
    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        $max = (int) config('coloringbook.authoring.max_image_kb');

        return [
            'title' => ['sometimes', 'required', 'string', 'max:120'],
            'blurb' => ['sometimes', 'nullable', 'string', 'max:500'],
            'is_free' => ['sometimes', 'boolean'],

            'cover' => ['sometimes', 'file', 'mimes:png', 'max:'.$max],
            'cover_asset_ulid' => ['sometimes', 'string', 'exists:assets,ulid'],
            'remove_cover' => ['sometimes', 'boolean'],
        ];
    }

    /**
     * @return array<string, string>
     */
    public function attributes(): array
    {
        return [
            'cover' => __('cover image'),
        ];
    }
}
