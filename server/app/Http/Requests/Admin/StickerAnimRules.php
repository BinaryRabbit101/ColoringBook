<?php

namespace App\Http\Requests\Admin;

use App\Services\StickerAnim;
use Illuminate\Contracts\Validation\Validator;

/**
 * The sprite-sheet metadata an animated sticker carries, as validation rules
 * (BL-38).
 *
 * The names and the shape are the **manifest's own** — `anim[hframes]` in a
 * form body is `"anim": {"hframes": …}` on the published entry — so there is one
 * vocabulary from the input to the pack and nothing in between has to translate.
 *
 * Three things worth knowing before touching this:
 *
 * - **All four or none.** `required_with` across the set makes a half-filled
 *   animation a validation error rather than a sticker that is "a bit
 *   animated".
 * - **A blank block is a still sticker, not an error.** `prepareAnimInput()`
 *   strips empty strings before the rules run, so an operator who left the whole
 *   animation section alone submits `anim = null` and gets exactly what they
 *   asked for. This matters because an HTML form posts `anim[hframes]=""` for a
 *   field nobody touched, and `nullable` does not cover `''`.
 * - **`frames ≤ hframes × vframes` is checked here as well as downstream.**
 *   `StickerValidation` catches it against the real pixels, but a form saying
 *   "a 2×2 sheet holds 4 frames" the moment the button is pressed beats a
 *   verdict appearing on the row afterwards.
 */
trait StickerAnimRules
{
    /**
     * Strip the empties out of a submitted `anim` block, and read an entirely
     * empty one as null. Call from `prepareForValidation()`.
     */
    protected function prepareAnimInput(): void
    {
        if (! $this->has('anim')) {
            return;
        }

        /** @var array<array-key, mixed> $raw */
        $raw = (array) $this->input('anim', []);
        $clean = [];

        foreach (StickerAnim::KEYS as $key) {
            $value = $raw[$key] ?? null;

            if ($value === null || $value === '') {
                continue;
            }

            $clean[$key] = $value;
        }

        $this->merge(['anim' => $clean === [] ? null : $clean]);
    }

    /**
     * @return array<string, mixed>
     */
    protected function animRules(): array
    {
        // Each field is required as soon as ANY of the four is there, which is
        // what "all four or none" means in `required_with`'s vocabulary.
        $together = 'required_with:anim.hframes,anim.vframes,anim.frames,anim.fps';

        return [
            'anim' => ['sometimes', 'nullable', 'array'],
            'anim.hframes' => [$together, 'integer', 'between:1,'.StickerAnim::MAX_GRID],
            'anim.vframes' => [$together, 'integer', 'between:1,'.StickerAnim::MAX_GRID],
            'anim.frames' => [$together, 'integer', 'min:1'],
            'anim.fps' => [
                $together,
                'numeric',
                'between:'.StickerAnim::MIN_FPS.','.StickerAnim::MAX_FPS,
            ],
        ];
    }

    /**
     * The cross-field rule: the frames have to fit in the cells there are.
     */
    protected function validateAnimFits(Validator $validator): void
    {
        $anim = StickerAnim::normalise($this->input('anim'));

        if ($anim === null) {
            return;
        }

        $cells = $anim['hframes'] * $anim['vframes'];

        if ($anim['frames'] > $cells) {
            $validator->errors()->add('anim.frames', __(
                'A :colsx:rows sheet holds :cells frames.',
                ['cols' => $anim['hframes'], 'rows' => $anim['vframes'], 'cells' => $cells],
            ));
        }
    }

    /**
     * @return array<string, string>
     */
    protected function animAttributes(): array
    {
        return [
            'anim.hframes' => __('columns'),
            'anim.vframes' => __('rows'),
            'anim.frames' => __('frame count'),
            'anim.fps' => __('frames per second'),
        ];
    }
}
