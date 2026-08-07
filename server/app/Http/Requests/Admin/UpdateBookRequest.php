<?php

namespace App\Http\Requests\Admin;

use Illuminate\Foundation\Http\FormRequest;

/**
 * `PATCH /admin/books/{book_uid}` — retitle (BL-24, §10.3).
 *
 * `book_uid` is absent by design and cannot be changed: it is the key every
 * saved page on every device hangs off (§6.1). Renaming a book means a new
 * book.
 */
class UpdateBookRequest extends FormRequest
{
    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        return [
            'title' => ['sometimes', 'required', 'string', 'max:120'],
            'blurb' => ['sometimes', 'nullable', 'string', 'max:500'],
            'is_free' => ['sometimes', 'boolean'],
        ];
    }
}
