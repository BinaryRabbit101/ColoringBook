<?php

namespace App\Http\Requests\Admin;

use App\Models\AuthoredSticker;
use App\Models\AuthoredStickerSet;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

/**
 * `PATCH /admin/sticker-sets/{set}/stickers/{index}` — retitle, reorder or
 * replace the art (BL-37).
 *
 * Every field is `sometimes`: this endpoint carries three unrelated edits and a
 * form that submits one of them must not be read as clearing the others.
 *
 * `sticker_id` is editable, unlike a book's `book_uid`, but only while nothing
 * has been published — the controller enforces that, because the rule is about
 * the *set's* release history rather than about this field's shape. Once a
 * version exists, a child somewhere has stuck that id on a page.
 */
class UpdateStickerRequest extends FormRequest
{
    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        $max = (int) config('coloringbook.authoring.max_image_kb');
        $setId = (int) (AuthoredStickerSet::query()
            ->where('set_uid', (string) $this->route('set'))
            ->value('id') ?? 0);
        $stickerId = (int) (AuthoredSticker::query()
            ->where('authored_sticker_set_id', $setId)
            ->where('sticker_index', (int) $this->route('index'))
            ->value('id') ?? 0);

        return [
            'title' => ['sometimes', 'nullable', 'string', 'max:120'],
            'sticker_index' => ['sometimes', 'integer', 'min:0', 'max:9999'],

            'sticker_id' => [
                'sometimes', 'required', 'string', 'max:64',
                'regex:/^[a-z0-9]+(-[a-z0-9]+)*$/',
                Rule::unique('authored_stickers', 'sticker_id')
                    ->where('authored_sticker_set_id', $setId)
                    ->ignore($stickerId),
            ],

            'image' => ['sometimes', 'file', 'mimes:png', 'max:'.$max],
            'image_asset_ulid' => ['sometimes', 'string', 'exists:assets,ulid'],
        ];
    }

    /**
     * @return array<string, string>
     */
    public function attributes(): array
    {
        return [
            'image' => __('sticker image'),
        ];
    }
}
