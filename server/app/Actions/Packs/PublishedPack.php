<?php

namespace App\Actions\Packs;

use App\Models\PackVersion;

/**
 * What publishing a pack directory produced.
 *
 * `warnings` are things worth telling the operator that are not reasons to
 * refuse — a manifest whose `pack_version` disagreed with the number the
 * server assigned, a page shipping a mask it shouldn't. WP5's
 * `POST /admin/packs/{slug}/versions` renders this as `{version, warnings[]}`
 * (errors arrive as a `PackPublishException` instead).
 */
class PublishedPack
{
    /**
     * @param  array<int, string>  $warnings
     */
    public function __construct(
        public readonly PackVersion $version,
        public readonly array $warnings = [],
    ) {}
}
