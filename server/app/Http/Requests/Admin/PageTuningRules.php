<?php

namespace App\Http\Requests\Admin;

/**
 * The per-page mapping overrides, as validation rules (BL-24, §10.3).
 *
 * The names and the ranges are the mapping pipeline's own
 * (`generate_region_map.gd`), so a page tuned in the browser can be reproduced
 * by hand on the dev box with the same flags — which is the whole point of
 * having one vocabulary for both. Anything the pipeline clamps, this refuses
 * instead: a silently clamped `--dilate -3` is a mapping nobody can explain.
 */
trait PageTuningRules
{
    /**
     * @return array<string, mixed>
     */
    protected function tuningRules(): array
    {
        return [
            'tuning' => ['sometimes', 'nullable', 'array'],
            'tuning.line_alpha_min' => ['nullable', 'numeric', 'between:0,1'],
            'tuning.line_luminance_max' => ['nullable', 'numeric', 'between:0,1'],
            'tuning.dilate' => ['nullable', 'integer', 'between:0,32'],
            'tuning.min_area' => ['nullable', 'integer', 'between:1,1000000'],
            'tuning.rdp' => ['nullable', 'numeric', 'between:0,64'],
            'tuning.giant_fraction' => ['nullable', 'numeric', 'between:0.01,1'],
        ];
    }
}
