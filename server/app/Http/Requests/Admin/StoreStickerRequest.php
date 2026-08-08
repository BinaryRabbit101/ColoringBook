<?php

namespace App\Http\Requests\Admin;

use App\Models\AuthoredStickerSet;
use Illuminate\Contracts\Validation\Validator;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

/**
 * `POST /admin/sticker-sets/{set}/stickers` — add a sticker (BL-37).
 *
 * One image, required; no mask, no tuning, no second half. That asymmetry with
 * `StorePageRequest` is the whole of §10.3's "no headless-Godot mapping step —
 * stickers have no regions; validation is image checks only".
 *
 * The image may arrive as a multipart file or as the ULID of an asset already
 * uploaded to `POST /admin/assets` (§11), hence the paired `required_without`.
 *
 * **PNG only.** A sticker is a cut-out laid over a child's drawing, and a
 * format with no alpha channel would paste a white box over it.
 *
 * `sticker_id` is unique WITHIN the set, not globally: two sets may both offer a
 * `star`, and a saved placement names the pair.
 */
class StoreStickerRequest extends FormRequest
{
    use StickerAnimRules;

    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        $max = (int) config('coloringbook.authoring.max_image_kb');
        // Scoped to THIS set: `sticker_id` is unique within a set, never
        // globally, and the route parameter is the only place the set is named.
        $setId = (int) (AuthoredStickerSet::query()
            ->where('set_uid', (string) $this->route('set'))
            ->value('id') ?? 0);

        return [
            'image' => ['required_without:image_asset_ulid', 'file', 'mimes:png', 'max:'.$max],
            'image_asset_ulid' => ['required_without:image', 'string', 'exists:assets,ulid'],

            'sticker_id' => [
                'required', 'string', 'max:64',
                'regex:/^[a-z0-9]+(-[a-z0-9]+)*$/',
                Rule::unique('authored_stickers', 'sticker_id')
                    ->where('authored_sticker_set_id', $setId),
            ],
            'title' => ['nullable', 'string', 'max:120'],

            // BL-38: absent means a still sticker, which is every sticker
            // authored before it.
            ...$this->animRules(),
        ];
    }

    protected function prepareForValidation(): void
    {
        $this->prepareAnimInput();
    }

    public function withValidator(Validator $validator): void
    {
        $validator->after(function (Validator $validator): void {
            $this->validateAnimFits($validator);
        });
    }

    /**
     * @return array<string, string>
     */
    public function attributes(): array
    {
        return [
            'image' => __('sticker image'),
            ...$this->animAttributes(),
        ];
    }

    /**
     * @return array<string, string>
     */
    public function messages(): array
    {
        return [
            'sticker_id.regex' => __('A sticker id is lowercase letters, digits and single hyphens — "paw-print". It is permanent within this set: every sticker a child has already stuck on a page names it.'),
            'sticker_id.unique' => __('This set already has a sticker with that id.'),
        ];
    }
}
