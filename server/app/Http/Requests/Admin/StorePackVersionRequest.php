<?php

namespace App\Http\Requests\Admin;

use Illuminate\Foundation\Http\FormRequest;

/**
 * `POST /admin/packs/{slug}/versions` in either of §11's two forms:
 *
 *   - `archive`  — the whole `pack.zip`, multipart. What a human uploads.
 *   - `manifest` + `assets` — a manifest plus `path → asset_ulid` for files
 *     already pushed to `POST /admin/assets`. What `pack build` uses, so a
 *     one-page fix re-uploads one page.
 *
 * Exactly one of the two: supplying both would leave "which bytes won?"
 * answerable only by reading this class.
 */
class StorePackVersionRequest extends FormRequest
{
    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        return [
            'archive' => [
                'required_without:manifest',
                'prohibits:manifest',
                'file',
                'max:'.(int) config('coloringbook.admin.max_upload_kb'),
            ],
            'manifest' => ['required_without:archive', 'array'],
            'assets' => ['required_with:manifest', 'array'],
            'assets.*' => ['required', 'string', 'max:64'],
            'is_free' => ['sometimes', 'nullable', 'boolean'],
        ];
    }

    /**
     * A multipart post cannot carry a nested object, so `manifest` may arrive
     * as a JSON string. Decode it here rather than in the controller: the
     * `array` rule below should see the same thing whichever content type the
     * caller used.
     */
    protected function prepareForValidation(): void
    {
        /** @var mixed $manifest */
        $manifest = $this->input('manifest');

        if (! is_string($manifest)) {
            return;
        }

        /** @var mixed $decoded */
        $decoded = json_decode($manifest, true);

        $this->merge(['manifest' => is_array($decoded) ? $decoded : $manifest]);
    }
}
