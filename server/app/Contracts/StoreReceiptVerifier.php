<?php

namespace App\Contracts;

use App\Services\Stores\ReceiptVerification;

/**
 * The one seam between this application and a platform store (
 * DLC_SERVER.md §9).
 *
 * `POST /entitlements/verify` hands a purchase token to whichever
 * implementation `coloringbook.stores.verifiers.<platform>` names, and writes
 * an entitlement only if the answer comes back valid. That is the whole of the
 * payments integration point: Phase 6 is "bind a real verifier and add the
 * billing plugin", not a schema change.
 *
 * An implementation must be **side-effect free** on the server's own state. It
 * talks to the store and reports; the entitlement is written by
 * `App\Actions\Entitlements\VerifyStoreReceipt`, which is also where the
 * idempotency and revoked-stays-revoked rules live.
 *
 * A store that is unreachable — network, credentials, quota — should throw
 * `App\Exceptions\ApiException` with `STORE_UNAVAILABLE` (503, retryable)
 * rather than returning `invalid`: "we could not ask" and "the store says no"
 * lead the client to do different things.
 */
interface StoreReceiptVerifier
{
    /**
     * @param  string  $platform  `google` | `apple` | `stripe`
     * @param  string  $purchaseToken  Whatever the platform's billing client handed the game.
     * @param  string  $sku  The product id the client believes it bought.
     */
    public function verify(string $platform, string $purchaseToken, string $sku): ReceiptVerification;
}
