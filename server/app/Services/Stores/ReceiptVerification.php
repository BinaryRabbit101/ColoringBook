<?php

namespace App\Services\Stores;

/**
 * What a `StoreReceiptVerifier` came back with.
 *
 * Two states and no third: the store recognised the purchase and named a
 * transaction, or it didn't. "We could not ask the store" is deliberately not
 * one of them — that is a `STORE_UNAVAILABLE` exception, because the client
 * should retry it rather than tell a parent their purchase was rejected.
 */
final class ReceiptVerification
{
    private function __construct(
        public readonly bool $valid,
        public readonly ?string $transactionId,
        public readonly ?string $reason,
    ) {}

    /**
     * @param  string  $transactionId  The store's own id for the purchase. It lands in
     *                                 `entitlements.platform_txn_id`, which is unique
     *                                 **per device** — the same purchase legitimately
     *                                 grants on every device signed into the store
     *                                 account (§4.3).
     */
    public static function valid(string $transactionId): self
    {
        return new self(true, $transactionId, null);
    }

    /**
     * @param  string  $reason  Operator-facing prose. Never returned to the client:
     *                          `RECEIPT_INVALID` carries a fixed message so a probe
     *                          learns nothing about how the check is made.
     */
    public static function invalid(string $reason): self
    {
        return new self(false, null, $reason);
    }
}
