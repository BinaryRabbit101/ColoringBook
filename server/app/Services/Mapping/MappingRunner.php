<?php

namespace App\Services\Mapping;

/**
 * The seam between the server and the mapping pipeline (BL-24, §10.3).
 *
 * There is exactly **one** implementation of the pipeline itself and it is
 * `godot/tools/generate_region_map.gd` — never a PHP port. §10.1 spent four
 * paragraphs on why the mapping logic must not be reimplemented, and a second
 * copy that drifts by one anti-aliasing threshold produces ID maps that
 * hit-test differently from every page ever shipped.
 *
 * So this interface exists for one reason only: **a shell-out is not testable
 * on a box with no engine.** `GodotMappingRunner` is the real thing; the test
 * suite binds a fake that drops pre-baked fixture artifacts into the same
 * scratch directory, which exercises every line either side of the process
 * boundary without needing a 160 MB binary in CI.
 */
interface MappingRunner
{
    public function run(MappingRequest $request): MappingResult;
}
