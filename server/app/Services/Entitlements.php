<?php

namespace App\Services;

use App\Exceptions\ApiException;
use App\Models\Entitlement;
use App\Models\Pack;
use Illuminate\Database\QueryException;
use Illuminate\Support\Collection;
use Symfony\Component\HttpFoundation\Response;

/**
 * The entitlement authority (DLC_SERVER.md §9).
 *
 * Everything that decides "may this owner have these bytes" goes through here,
 * and the answer is always a row in `entitlements` — there is no implicit
 * ownership anywhere in the codebase.
 *
 * ## Two owners, one set of rules (BL-52)
 *
 * Every method takes an `EntitlementOwner`, which is either a parent account or
 * an anonymous device (§4.3). Nothing below cares which: grant, regrant,
 * revoke and the free-claim all mean exactly what they used to, per owner.
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
 *   - a revoked free pack's **row** stays revoked, because the grant only ever
 *     fires when there is no row at all. Un-revoking is a deliberate admin act
 *     (WP5), never a side effect of the client retrying a download;
 *   - Phase 6 can turn a free pack paid without changing a line of gating.
 *
 * Since BL-52 a free pack's *bytes* are public (§7.4) — the row governs
 * `owned`, not access — so `authorise()` is only ever consulted for paid packs.
 * `claimFree()` is the half that still runs on a free fetch when a token
 * happens to be present.
 *
 * The catalog's `owned` flag reflects a live row, so a free pack reads
 * `{"is_free": true, "owned": false}` until it is first fetched by a token.
 */
class Entitlements
{
    /**
     * Authorise a download of a **paid** pack. Throws `ENTITLEMENT_REQUIRED`
     * for anything unowned or revoked.
     */
    public function authorise(EntitlementOwner $owner, Pack $pack): Entitlement
    {
        $existing = $this->find($owner, $pack);

        if ($existing !== null) {
            if (! $existing->isLive()) {
                throw $this->required();
            }

            return $existing;
        }

        if ($pack->is_free) {
            return $this->grant($owner, $pack, Entitlement::SOURCE_FREE);
        }

        throw $this->required();
    }

    /**
     * The free-claim, on its own: a free pack writes itself a row the first
     * time a token fetches it, and never touches an existing one — so a
     * deliberately revoked claim is not resurrected by a retry (BL-52 keeps
     * that rule verbatim while making the *bytes* public).
     */
    public function claimFree(EntitlementOwner $owner, Pack $pack): ?Entitlement
    {
        if (! $pack->is_free) {
            return null;
        }

        return $this->grant($owner, $pack, Entitlement::SOURCE_FREE);
    }

    /**
     * Does this owner currently own the pack? No grants, no exceptions — this
     * is what paints the catalog's `owned` flag.
     */
    public function owns(EntitlementOwner $owner, Pack $pack): bool
    {
        return $this->find($owner, $pack)?->isLive() === true;
    }

    /**
     * The pack ids this owner currently owns, for painting a whole listing
     * without an N+1.
     *
     * @return array<int, int>
     */
    public function ownedPackIds(EntitlementOwner $owner): array
    {
        /** @var array<int, int> $ids */
        $ids = $owner->entitlements()->live()->pluck('pack_id')->all();

        return $ids;
    }

    /**
     * Every live claim, newest grant first, with the pack eager-loaded — the
     * shape `GET /entitlements` reports and the client's update check reads.
     *
     * @return Collection<int, Entitlement>
     */
    public function live(EntitlementOwner $owner): Collection
    {
        /** @var Collection<int, Entitlement> $entitlements */
        $entitlements = $owner->entitlements()
            ->live()
            ->with('pack')
            ->orderByDesc('granted_at')
            ->orderBy('id')
            ->get();

        return $entitlements;
    }

    /**
     * Write a claim, if there isn't one. Idempotent on (owner, pack).
     *
     * The owner columns are stamped by `EntitlementOwner` rather than
     * mass-assigned: who owns what is never something a request body gets to
     * say, so neither is fillable.
     *
     * The `QueryException` catch is not defensive noise — two of a household's
     * tablets opening the same free pack at the same second is an ordinary
     * Tuesday, and the unique index is what makes that safe. Losing the race
     * means the other request already granted it.
     */
    public function grant(
        EntitlementOwner $owner,
        Pack $pack,
        string $source,
        ?string $platform = null,
        ?string $platformTxnId = null,
    ): Entitlement {
        $existing = $this->find($owner, $pack);

        if ($existing !== null) {
            return $existing;
        }

        $entitlement = new Entitlement;
        $owner->stamp($entitlement);
        $entitlement->pack_id = $pack->id;
        $entitlement->source = $source;
        $entitlement->platform = $platform;
        $entitlement->platform_txn_id = $platformTxnId;
        $entitlement->granted_at = now();

        try {
            $entitlement->save();
        } catch (QueryException $e) {
            return $this->find($owner, $pack) ?? throw $e;
        }

        return $entitlement;
    }

    /**
     * The admin's deliberate act: grant, or bring a **revoked** claim back to
     * life (WP5, §10.2).
     *
     * `grant()` never touches an existing row, on purpose — a revoked pack
     * must stay revoked no matter how often the client retries a download or
     * re-presents a receipt. That leaves exactly one way back, and this is it:
     * clearing `revoked_at` and re-stamping `granted_at`, so the row reads as a
     * fresh claim while remaining the same auditable row.
     *
     * Idempotent in both directions: re-granting a live claim is a no-op, and
     * re-granting a revoked one un-revokes it once.
     */
    public function regrant(EntitlementOwner $owner, Pack $pack, string $source): Entitlement
    {
        $existing = $this->find($owner, $pack);

        if ($existing === null) {
            return $this->grant($owner, $pack, $source);
        }

        if ($existing->isLive()) {
            return $existing;
        }

        $existing->revoked_at = null;
        $existing->source = $source;
        $existing->granted_at = now();
        $existing->save();

        return $existing;
    }

    /**
     * Withdraw a claim without deleting it — a tombstone, so a refund stays
     * auditable and coming back is a decision rather than an accident (§9).
     */
    public function revoke(EntitlementOwner $owner, Pack $pack): ?Entitlement
    {
        $existing = $this->find($owner, $pack);

        if ($existing === null || ! $existing->isLive()) {
            return $existing;
        }

        $existing->revoked_at = now();
        $existing->save();

        return $existing;
    }

    public function find(EntitlementOwner $owner, Pack $pack): ?Entitlement
    {
        /** @var Entitlement|null $entitlement */
        $entitlement = $owner->entitlements()->where('pack_id', $pack->id)->first();

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
