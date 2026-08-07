<?php

namespace App\Http\Requests\Admin;

use Illuminate\Foundation\Http\FormRequest;

/**
 * `POST /admin/sticker-sets` — create a sticker set and its one-set pack
 * (BL-37).
 *
 * `set_uid` is checked for uniqueness three times over, exactly as
 * `StoreBookRequest` checks `book_uid`, and each one is a different fact:
 *
 * - `authored_sticker_sets` — no two drafts may claim the same uid;
 * - `sticker_sets` — no published release may already own it, because uids are
 *   never reused (§6.1) and every sticker a child has stuck on a page names one;
 * - `packs.slug` — a web-authored set's pack takes its uid as its slug, and a
 *   slug is the pack's permanent address in every URL the game builds.
 *
 * `packs.slug` is shared with books, so a set can also not take a book's slug —
 * which is correct: they are the same namespace on the wire.
 */
class StoreStickerSetRequest extends FormRequest
{
    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        return [
            'set_uid' => [
                'required', 'string', 'max:64',
                'regex:/^[a-z0-9]+(-[a-z0-9]+)*$/',
                'unique:authored_sticker_sets,set_uid',
                'unique:sticker_sets,set_uid',
                'unique:packs,slug',
            ],
            'title' => ['required', 'string', 'max:120'],
            'blurb' => ['nullable', 'string', 'max:500'],
            'sort_order' => ['sometimes', 'integer', 'min:0', 'max:9999'],
            'is_free' => ['sometimes', 'boolean'],
        ];
    }

    /**
     * @return array<string, string>
     */
    public function messages(): array
    {
        return [
            'set_uid.regex' => __('A sticker-set id is lowercase letters, digits and single hyphens — "starter-stickers-2026". It is permanent: every sticker a child has already stuck on a page names it.'),
            'set_uid.unique' => __('That id is already taken.'),
        ];
    }
}
