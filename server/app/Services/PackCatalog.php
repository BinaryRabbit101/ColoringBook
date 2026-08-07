<?php

namespace App\Services;

use App\Exceptions\ApiException;
use App\Models\Pack;
use App\Models\PackVersion;
use Illuminate\Database\Eloquent\Collection;
use Symfony\Component\HttpFoundation\Response;

/**
 * Reading the catalog the way §11 describes it.
 *
 * The one piece of real logic here is `min_client_version` filtering (§7.3).
 * A pack that needs a newer game build must be **invisible** to older ones
 * rather than offered and then crashed on — and because a pack can have many
 * published versions, "invisible" is per *version*: a v4 that needs 0.8.0
 * simply isn't the answer for a 0.7.0 client, which still sees v3.
 *
 * The comparison is `version_compare`, so `0.10.0` correctly beats `0.9.0`;
 * it happens in PHP rather than SQL because there is no portable semver
 * ordering in SQLite and a catalog is a few dozen rows.
 */
class PackCatalog
{
    /**
     * Every pack the shop may show, newest release resolved for this client.
     *
     * @return Collection<int, Pack>
     */
    public function listable(?string $clientVersion): Collection
    {
        /** @var Collection<int, Pack> $packs */
        $packs = Pack::query()
            ->listable()
            ->with(['versions' => fn ($query) => $query->published(), 'books.pages', 'stickerSets.stickers'])
            ->orderBy('sort_order')
            ->orderBy('title')
            ->get();

        // A published pack with nothing published inside it is not a product.
        return $packs->filter(
            fn (Pack $pack): bool => $this->latestVersion($pack, $clientVersion) !== null,
        )->values();
    }

    /**
     * The newest published version this client can actually use, or null.
     */
    public function latestVersion(Pack $pack, ?string $clientVersion = null): ?PackVersion
    {
        $versions = $pack->relationLoaded('versions')
            ? $pack->versions->filter(fn (PackVersion $version): bool => $version->published_at !== null)
            : $pack->versions()->published()->get();

        return $versions
            ->filter(fn (PackVersion $version): bool => $this->supports($version, $clientVersion))
            ->sortByDesc('version')
            ->first();
    }

    /**
     * A pack the shop is allowed to show. Draft and retired are 404, not 403:
     * the catalog never confirms that an unlisted slug exists.
     */
    public function findListable(string $slug): Pack
    {
        /** @var Pack */
        return Pack::query()->listable()->where('slug', $slug)->firstOrFail();
    }

    /**
     * A pack an owner is allowed to fetch. Wider than `findListable` on
     * purpose: a retired pack is delisted, but the household that owns it
     * keeps every byte (§7.3).
     */
    public function findDownloadable(string $slug): Pack
    {
        /** @var Pack */
        return Pack::query()->downloadable()->where('slug', $slug)->firstOrFail();
    }

    /**
     * Resolve `?version=`. Absent means "the newest one", which is what a
     * first install asks for; an explicit number is what a delta update asks
     * for, and asking for one that was never published is a hard error rather
     * than a silent fallback — installing the wrong version would corrupt the
     * client's per-pack version bookkeeping.
     */
    public function versionOrLatest(Pack $pack, ?int $version, ?string $clientVersion = null): PackVersion
    {
        if ($version === null) {
            $latest = $this->latestVersion($pack, $clientVersion);

            if ($latest === null) {
                throw $this->missingVersion();
            }

            return $latest;
        }

        /** @var PackVersion|null $found */
        $found = $pack->versions()->published()->where('version', $version)->first();

        if ($found === null) {
            throw $this->missingVersion();
        }

        return $found;
    }

    private function supports(PackVersion $version, ?string $clientVersion): bool
    {
        if ($clientVersion === null || $clientVersion === '' || $version->min_client_version === null) {
            return true;
        }

        return version_compare($clientVersion, $version->min_client_version, '>=');
    }

    private function missingVersion(): ApiException
    {
        return new ApiException(
            'PACK_VERSION_NOT_FOUND',
            __('That version of the pack does not exist.'),
            Response::HTTP_NOT_FOUND,
        );
    }
}
