<?php

namespace App\Http\Requests\Admin;

use Illuminate\Foundation\Http\FormRequest;

/**
 * `POST /admin/books/{book_uid}/pages` — add a page (BL-24, §10.3).
 *
 * **The detail image is required; the mask is not.** That asymmetry is BL-9's
 * rule and it is the whole page model: every page has a visible image, and a
 * masking image is an optional extra that, when present, becomes the mapping
 * source and ships as a layer under the art (BL-12).
 *
 * Either half may arrive as a multipart file or as the ULID of an asset already
 * uploaded to `POST /admin/assets` (§11) — hence the paired
 * `required_without`.
 *
 * PNG only, and deliberately so: the ID map generated from this art has to stay
 * lossless or region ids bleed (DESIGN.md §3.2), and a JPEG display image
 * beside a lossless ID map is a page whose lines do not sit where the mapping
 * thinks they do.
 */
class StorePageRequest extends FormRequest
{
    use PageTuningRules;

    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        $max = (int) config('coloringbook.authoring.max_image_kb');

        return [
            'display' => ['required_without:display_asset_ulid', 'file', 'mimes:png', 'max:'.$max],
            'display_asset_ulid' => ['required_without:display', 'string', 'exists:assets,ulid'],

            'mask' => ['nullable', 'file', 'mimes:png', 'max:'.$max],
            'mask_asset_ulid' => ['nullable', 'string', 'exists:assets,ulid'],

            'title' => ['nullable', 'string', 'max:120'],
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
