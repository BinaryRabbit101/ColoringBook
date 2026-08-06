<?php

namespace App\Http\Requests\Admin;

use Illuminate\Foundation\Http\FormRequest;

/**
 * `POST /admin/packs` — the empty shelf a pack's versions get filed under.
 *
 * The pack row exists before any artwork does, so the operator can reserve a
 * slug (which is the pack's permanent address in §11) and hang drafts off it.
 * It is created as a **draft**: `Pack`'s attribute defaults say so, and
 * publishing the first version is what puts it in the catalog.
 */
class StorePackRequest extends FormRequest
{
    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        return [
            // Lowercase, hyphenated, and immutable afterwards: this string is
            // in every URL the game will ever build for the pack.
            'slug' => ['required', 'string', 'max:64', 'regex:/^[a-z0-9]+(-[a-z0-9]+)*$/', 'unique:packs,slug'],
            'title' => ['required', 'string', 'max:120'],
            'blurb' => ['nullable', 'string', 'max:500'],
            'is_free' => ['sometimes', 'boolean'],
            'sort_order' => ['sometimes', 'integer', 'min:0', 'max:9999'],
        ];
    }

    /**
     * @return array<string, string>
     */
    public function messages(): array
    {
        return [
            'slug.regex' => __('A slug is lowercase letters, digits and single hyphens — it becomes part of every pack URL.'),
        ];
    }
}
