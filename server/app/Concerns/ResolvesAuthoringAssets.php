<?php

namespace App\Concerns;

use App\Actions\Admin\StoreUploadedAsset;
use App\Models\Asset;
use App\Models\AuthoredPage;
use Illuminate\Http\Request;
use Illuminate\Http\UploadedFile;

/**
 * §11 lets a page's art arrive two ways — "multipart detail + optional mask, or
 * asset ulids" — and this is where they converge (BL-24).
 *
 * The multipart form is what the browser posts. The ULID form is what a script
 * posts after `POST /admin/assets`, and it exists for the same reason it does
 * on the pack-version endpoint: a 40 MB page that has already been uploaded
 * should not be uploaded again.
 *
 * Either way the result is an `assets` row, content-addressed, so the two paths
 * are indistinguishable downstream — and re-posting identical bytes is free.
 */
trait ResolvesAuthoringAssets
{
    /**
     * @param  string  $kind  The `assets.kind` an *uploaded* file is filed
     *                        under. An asset named by ULID keeps whatever kind
     *                        it was stored with: the row already exists and its
     *                        digest is what matters to everything downstream.
     * @return Asset|null null when neither field was supplied
     */
    protected function resolveAsset(Request $request, string $fileField, string $ulidField, string $kind): ?Asset
    {
        $file = $request->file($fileField);

        if ($file instanceof UploadedFile) {
            return app(StoreUploadedAsset::class)->handle($file, $kind);
        }

        $ulid = trim((string) $request->input($ulidField, ''));

        if ($ulid === '') {
            return null;
        }

        /** @var Asset|null */
        return Asset::query()->where('ulid', $ulid)->first();
    }

    /**
     * The edits a `PATCH` body actually asks for — §11's "title, reorder,
     * replace detail/mask" read once, for both doors.
     *
     * Every key is present only when the request asked for it: this endpoint
     * carries four unrelated edits, and a form submitting one of them must not
     * be read as clearing the other three.
     *
     * @return array{
     *     title?: string|null,
     *     page_index?: int,
     *     display?: Asset,
     *     mask?: Asset|null,
     *     tuning?: array<string, float|int>|null,
     * }
     */
    protected function pageChanges(Request $request): array
    {
        $changes = [];

        if ($request->has('title')) {
            $title = trim((string) $request->string('title'));
            $changes['title'] = $title === '' ? null : $title;
        }

        if ($request->has('page_index')) {
            $changes['page_index'] = (int) $request->integer('page_index');
        }

        $display = $this->resolveAsset($request, 'display', 'display_asset_ulid', 'display');

        if ($display instanceof Asset) {
            $changes['display'] = $display;
        }

        if ($request->boolean('remove_mask')) {
            $changes['mask'] = null;
        } else {
            $mask = $this->resolveAsset($request, 'mask', 'mask_asset_ulid', 'mask');

            if ($mask instanceof Asset) {
                $changes['mask'] = $mask;
            }
        }

        if ($request->has('tuning')) {
            $changes['tuning'] = $this->resolveTuning($request);
        }

        return $changes;
    }

    /**
     * The edits a book `PATCH` body asks for (BL-24 + BL-38's cover), read once
     * for both doors.
     *
     * `$validated` carries the scalar fields the FormRequest already checked;
     * the cover is resolved off the raw request because it is a file or a ULID,
     * which validation cannot turn into an `assets` row.
     *
     * @param  array<string, mixed>  $validated
     * @return array{title?: string, blurb?: string|null, is_free?: bool, cover?: Asset|null}
     */
    protected function bookChanges(Request $request, array $validated): array
    {
        /** @var array{title?: string, blurb?: string|null, is_free?: bool, cover?: Asset|null} $changes */
        $changes = array_intersect_key($validated, array_flip(['title', 'blurb', 'is_free']));

        // A deliberately cleared cover and an untouched one look identical in a
        // multipart body, so removal is its own boolean — the `remove_mask`
        // rule, one level up.
        if ($request->boolean('remove_cover')) {
            $changes['cover'] = null;
        } else {
            $cover = $this->resolveAsset($request, 'cover', 'cover_asset_ulid', 'cover');

            if ($cover instanceof Asset) {
                $changes['cover'] = $cover;
            }
        }

        return $changes;
    }

    /**
     * The per-page tuning overrides, normalised to the knobs the pipeline
     * actually has. An empty submission is **null**, not `[]`, so "this page
     * uses the defaults" is one value rather than two.
     *
     * @return array<string, float|int>|null
     */
    protected function resolveTuning(Request $request, string $field = 'tuning'): ?array
    {
        /** @var array<array-key, mixed> $raw */
        $raw = $request->array($field);
        $tuning = [];

        foreach (array_keys(AuthoredPage::TUNING_FLAGS) as $name) {
            $value = $raw[$name] ?? null;

            if ($value === null || $value === '') {
                continue;
            }

            $tuning[$name] = in_array($name, ['dilate', 'min_area'], true)
                ? (int) $value
                : (float) $value;
        }

        return $tuning === [] ? null : $tuning;
    }
}
