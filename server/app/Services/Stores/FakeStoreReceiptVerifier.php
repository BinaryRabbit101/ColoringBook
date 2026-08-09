<?php

namespace App\Services\Stores;

use App\Contracts\StoreReceiptVerifier;

/**
 * The dev/test stand-in for a real store (BL-52, DLC_SERVER.md §9).
 *
 * It exists so the whole receipt → entitlement → download path can be built and
 * tested before Play/App Store credentials exist, and so Phase 6 is a *binding*
 * change rather than a schema change.
 *
 * Deterministic by construction: a purchase token is valid **iff** it starts
 * with `coloringbook.stores.fake.prefix` (default `test-`), and the
 * transaction id it reports is the purchase token itself. No clock, no
 * randomness, no network — the same call answers the same way forever, which is
 * what makes "verify twice, get one row" a real assertion rather than a lucky
 * one.
 *
 * **It cannot be switched on by accident in production.** Two locks, and both
 * matter:
 *
 *  1. `coloringbook.stores.verifiers.*` ships as **all null**, so an
 *     unconfigured deployment answers `STORE_UNAVAILABLE` for every platform
 *     rather than falling back to anything.
 *  2. `StoreReceipts` refuses to hand this class out when the app environment
 *     is production, whatever the config says — so a copied `.env` cannot turn
 *     a real store into a rubber stamp.
 */
class FakeStoreReceiptVerifier implements StoreReceiptVerifier
{
    public function verify(string $platform, string $purchaseToken, string $sku): ReceiptVerification
    {
        $prefix = (string) config('coloringbook.stores.fake.prefix');

        if ($prefix !== '' && ! str_starts_with($purchaseToken, $prefix)) {
            return ReceiptVerification::invalid(
                'The fake verifier only accepts purchase tokens beginning "'.$prefix.'".',
            );
        }

        return ReceiptVerification::valid($purchaseToken);
    }
}
