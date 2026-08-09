<?php

namespace App\Actions\Entitlements;

use App\Exceptions\ApiException;
use App\Models\Device;
use App\Models\Entitlement;
use App\Services\Entitlements;
use App\Services\Stores\StoreReceipts;
use Symfony\Component\HttpFoundation\Response;

/**
 * `POST /api/v1/entitlements/verify` — the restore path (DLC_SERVER.md §9,
 * §4.3).
 *
 * The client hands over `{platform, purchase_token, sku}`; the server resolves
 * the pack from the SKU, asks the platform's `StoreReceiptVerifier` whether the
 * purchase is real, and writes a `source = 'purchase'` row to **the device the
 * token names**.
 *
 * ## Restore purchases is the whole point
 *
 * The store account is the cross-device identity, not us. Play Billing and
 * StoreKit hand the same purchase tokens to every device signed into the same
 * store account, so a household's second tablet installs the game, registers
 * itself (§4.3), asks the store what it owns and re-verifies each token — and
 * gets its own entitlement rows for packs bought on the first tablet. No email,
 * no password, no double purchase.
 *
 * That is why `platform_txn_id` uniqueness is **per device** rather than
 * global: the same receipt is *supposed* to be claimable by more than one
 * device, and Google Play requires non-consumables to be restorable. Within one
 * device it is still once-only, so a replayed receipt cannot mint a second row.
 *
 * Three refusals, and they mean different things to the client:
 *
 *  - `RECEIPT_INVALID` (422) — the store says no. Stop; do not retry.
 *  - `STORE_UNAVAILABLE` (503) — we could not ask. Retry later.
 *  - `ENTITLEMENT_REQUIRED` (403) — this device has the pack **revoked**. A
 *    receipt is not a way back: `Entitlements::grant()` never touches an
 *    existing row, and un-revoking is a deliberate admin act (WP5). Re-using
 *    the code the download path already answers with keeps the client's
 *    branch count where it was.
 */
class VerifyStoreReceipt
{
    public function __construct(
        private readonly StoreReceipts $stores,
        private readonly Entitlements $entitlements,
    ) {}

    public function handle(
        Device $device,
        string $platform,
        string $purchaseToken,
        string $sku,
    ): Entitlement {
        $pack = $this->stores->packForSku($platform, $sku);

        $existing = $this->entitlements->find($device, $pack);

        // Idempotent per (device, pack), and cheap: a re-verify on every launch
        // should not spend a round trip to Google for a pack we already wrote.
        if ($existing !== null) {
            if (! $existing->isLive()) {
                throw new ApiException(
                    'ENTITLEMENT_REQUIRED',
                    __('This device does not own that pack.'),
                    Response::HTTP_FORBIDDEN,
                );
            }

            return $existing;
        }

        $verification = $this->stores->verifierFor($platform)
            ->verify($platform, $purchaseToken, $sku);

        if (! $verification->valid) {
            // The verifier's own reason stays server-side: a probe learns
            // nothing about how the check is made.
            throw new ApiException(
                'RECEIPT_INVALID',
                __('That purchase could not be verified.'),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        return $this->entitlements->grant(
            $device,
            $pack,
            Entitlement::SOURCE_PURCHASE,
            $platform,
            $verification->transactionId,
        );
    }
}
