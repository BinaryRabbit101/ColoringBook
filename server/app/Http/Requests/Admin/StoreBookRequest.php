<?php

namespace App\Http\Requests\Admin;

use Illuminate\Foundation\Http\FormRequest;

/**
 * `POST /admin/books` — create a book and its one-book pack (BL-24, §10.3).
 *
 * `book_uid` is checked for uniqueness **three times over**, and each one is a
 * different fact:
 *
 * - `authored_books` — no two drafts may claim the same uid;
 * - `books` — no published release may already own it, in this pack or any
 *   other, because uids are never reused (§6.1) and every `book_progress` row
 *   on every device keys off one;
 * - `packs.slug` — a web-authored book's pack takes its uid as its slug, and a
 *   slug is the pack's permanent address in every URL the game builds.
 *
 * All three read the same submitted string, so the operator gets one field
 * error rather than a surprise at publish time.
 */
class StoreBookRequest extends FormRequest
{
    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        return [
            'book_uid' => [
                'required', 'string', 'max:64',
                'regex:/^[a-z0-9]+(-[a-z0-9]+)*$/',
                'unique:authored_books,book_uid',
                'unique:books,book_uid',
                'unique:packs,slug',
            ],
            'title' => ['required', 'string', 'max:120'],
            'blurb' => ['nullable', 'string', 'max:500'],
            'is_free' => ['sometimes', 'boolean'],
        ];
    }

    /**
     * @return array<string, string>
     */
    public function messages(): array
    {
        return [
            'book_uid.regex' => __('A book id is lowercase letters, digits and single hyphens — "coyote-2026". It is permanent: every saved page on every device keys off it.'),
            'book_uid.unique' => __('That book id is already taken.'),
        ];
    }
}
