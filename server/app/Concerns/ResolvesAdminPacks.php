<?php

namespace App\Concerns;

use App\Models\Pack;
use App\Models\PackVersion;

/**
 * Looking a pack up **without** the catalog's status filter.
 *
 * `PackCatalog::findListable()` deliberately 404s on drafts and retired packs
 * so the shop never confirms an unlisted slug exists. The admin is the one
 * caller for whom that is wrong: drafts are precisely what it works on. Kept
 * as a trait so the JSON API and the Inertia pages resolve a slug the same
 * way, and neither is tempted to reach for the catalog service and quietly
 * lose sight of every draft.
 */
trait ResolvesAdminPacks
{
    protected function adminPack(string $slug, bool $withVersions = false): Pack
    {
        $query = Pack::query()->where('slug', $slug);

        if ($withVersions) {
            $query->with('versions');
        }

        /** @var Pack */
        return $query->firstOrFail();
    }

    protected function adminVersion(Pack $pack, int $version): PackVersion
    {
        /** @var PackVersion */
        return $pack->versions()->where('version', $version)->firstOrFail();
    }
}
