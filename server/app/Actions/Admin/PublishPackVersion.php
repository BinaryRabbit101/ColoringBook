<?php

namespace App\Actions\Admin;

use App\Exceptions\ApiException;
use App\Models\Pack;
use App\Models\PackVersion;
use Illuminate\Support\Facades\DB;
use Symfony\Component\HttpFoundation\Response;

/**
 * `POST /admin/packs/{slug}/versions/{v}/publish` — the one irreversible
 * button in the admin tool (DLC_SERVER.md §7.3, §10.2).
 *
 * It stamps `published_at` and, if the pack was still a draft, moves the pack
 * itself into the catalog. Nothing else changes: the manifest, the archive and
 * the digest were all written when the draft was created, so publishing is
 * pure visibility and a client that already downloaded the draft's bytes (it
 * cannot) would find them identical.
 *
 * **Published rows are immutable.** Republishing is `max(version) + 1`, never
 * a rewrite, which is what makes the client's "installed version per pack"
 * check a plain integer comparison. So re-publishing an already-published
 * version is a `409`, not a silent no-op: if the operator meant to ship a fix,
 * quietly agreeing would leave every device believing it is up to date.
 *
 * Retiring is *not* here. Delisting a pack must never take books away from a
 * household that owns them (§7.3), and the catalog already serves retired
 * packs to their owners — so retirement is a status change on `packs`, not
 * something that touches a release.
 */
class PublishPackVersion
{
    public function handle(PackVersion $version): PackVersion
    {
        if ($version->published_at !== null) {
            throw new ApiException(
                'PACK_VERSION_ALREADY_PUBLISHED',
                __('That version is already published; publish a new version instead.'),
                Response::HTTP_CONFLICT,
            );
        }

        return DB::transaction(function () use ($version): PackVersion {
            $version->published_at = now();
            $version->save();

            $pack = $version->pack;

            if ($pack->status === Pack::STATUS_DRAFT) {
                $pack->status = Pack::STATUS_PUBLISHED;
                $pack->save();
            }

            return $version;
        });
    }
}
