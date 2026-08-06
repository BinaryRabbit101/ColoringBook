<?php

namespace App\Services;

use App\Exceptions\ApiException;
use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\User;
use Illuminate\Database\QueryException;
use Illuminate\Support\Collection;
use Symfony\Component\HttpFoundation\Response;

/**
 * The entitlement authority (DLC_SERVER.md §9).
 *
 * Everything that decides "may this account have these bytes" goes through
 * here, and the answer is always a row in `entitlements` — there is no
 * implicit ownership anywhere in the codebase.
 *
 * ## Free packs
 *
 * `packs.is_free` is not, by itself, ownership. A free pack **auto-grants**
 * itself the first time an authenticated device asks for its manifest or its
 * bytes, writing a real `source = 'free'` row. That keeps a single rule —
 * "rows drive everything" — while still costing the player nothing:
 *
 *   - `GET /entitlements` stays an honest inventory of what a device should
 *     have installed, rather than the catalog in disguise;
 *   - a revoked free pack *stays* revoked, because the grant only ever fires
 *     when there is no row at all. Un-revoking is a deliberate admin act
 *     (WP5), never a side effect of the client retrying a download;
 *   - Phase 6 can turn a free pack paid without changing a line of gating.
 *
 * The catalog's `owned` flag reflects a live row, so a free pack reads
 * `{"is_free": true, "owned": false}` until it is first fetched. The client
 * offers a download for either.
 */
class Entitlements
{
    /**
     * Authorise a download, granting a free pack to this account on the way
     * through. Throws `ENTITLEMENT_REQUIRED` for anything else unowned.
     */
    public function authorise(User $user, Pack $pack): Entitlement
    {
        $existing = $this->find($user, $pack);

        if ($existing !== null) {
            if (! $existing->isLive()) {
                throw $this->required();
            }

            return $existing;
        }

        if ($pack->is_free) {
            return $this->grant($user, $pack, Entitlement::SOURCE_FREE);
        }

        throw $this->required();
    }

    /**
     * Does this account currently own the pack? No grants, no exceptions —
     * this is what paints the catalog's `owned` flag.
     */
    public function owns(User $user, Pack $pack): bool
    {
        return $this->find($user, $pack)?->isLive() === true;
    }

    /**
     * The pack ids this account currently owns, for painting a whole listing
     * without an N+1.
     *
     * @return array<int, int>
     */
    public function ownedPackIds(User $user): array
    {
        /** @var array<int, int> $ids */
        $ids = $user->entitlements()->live()->pluck('pack_id')->all();

        return $ids;
    }

    /**
     * Every live claim, newest grant first, with the pack eager-loaded — the
     * shape `GET /entitlements` reports and the client's update check reads.
     *
     * @return Collection<int, Entitlement>
     */
    public function live(User $user): Collection
    {
        /** @var Collection<int, Entitlement> $entitlements */
        $entitlements = $user->entitlements()
            ->live()
            ->with('pack')
            ->orderByDesc('granted_at')
            ->orderBy('id')
            ->get();

        return $entitlements;
    }

    /**
     * Write a claim, if there isn't one. Idempotent on (user, pack).
     *
     * `user_id`/`pack_id` are set directly rather than mass-assigned: who owns
     * what is never something a request body gets to say, so neither column is
     * fillable.
     *
     * The `QueryException` catch is not defensive noise — two of a household's
     * tablets opening the same free pack at the same second is an ordinary
     * Tuesday, and the unique index is what makes that safe. Losing the race
     * means the other request already granted it.
     */
    public function grant(
        User $user,
        Pack $pack,
        string $source,
        ?string $platform = null,
        ?string $platformTxnId = null,
    ): Entitlement {
        $existing = $this->find($user, $pack);

        if ($existing !== null) {
            return $existing;
        }

        $entitlement = new Entitlement;
        $entitlement->user_id = $user->id;
        $entitlement->pack_id = $pack->id;
        $entitlement->source = $source;
        $entitlement->platform = $platform;
        $entitlement->platform_txn_id = $platformTxnId;
        $entitlement->granted_at = now();

        try {
            $entitlement->save();
        } catch (QueryException $e) {
            return $this->find($user, $pack) ?? throw $e;
        }

        return $entitlement;
    }

    private function find(User $user, Pack $pack): ?Entitlement
    {
        /** @var Entitlement|null $entitlement */
        $entitlement = Entitlement::query()
            ->where('user_id', $user->id)
            ->where('pack_id', $pack->id)
            ->first();

        return $entitlement;
    }

    /**
     * The one failure the game client branches on here: it hides the pack's
     * books from the shelf and leaves every already-painted pixel alone.
     */
    private function required(): ApiException
    {
        return new ApiException(
            'ENTITLEMENT_REQUIRED',
            __('This account does not own that pack.'),
            Response::HTTP_FORBIDDEN,
        );
    }
}
