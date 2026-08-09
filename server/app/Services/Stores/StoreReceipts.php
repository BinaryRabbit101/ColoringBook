<?php

namespace App\Services\Stores;

use App\Contracts\StoreReceiptVerifier;
use App\Exceptions\ApiException;
use App\Models\Pack;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;

/**
 * Everything `POST /entitlements/verify` needs to know about stores that isn't
 * the verification itself (BL-52, DLC_SERVER.md §9).
 *
 * Two jobs, both config-driven:
 *
 *  - **which verifier answers for a platform** — `coloringbook.stores.verifiers`
 *    maps `google|apple|stripe` to a class name implementing
 *    `StoreReceiptVerifier`. A platform with no class configured is not an
 *    error in the code, it is a `STORE_UNAVAILABLE` (503, retryable) answer:
 *    the store half of Phase 6 simply is not wired up on this deployment yet.
 *  - **which SKU column a platform reads** — `packs.sku_google` / `sku_apple` /
 *    `sku_stripe`. The client tells us the product id it bought; the pack is
 *    resolved from it, never from a slug the client also sends, so a client
 *    cannot pair somebody else's receipt with a pack of its choosing.
 */
class StoreReceipts
{
    /**
     * Resolve the verifier for a platform, or refuse in a way the client can
     * retry.
     */
    public function verifierFor(string $platform): StoreReceiptVerifier
    {
        /** @var array<string, string|null> $verifiers */
        $verifiers = config('coloringbook.stores.verifiers', []);

        $class = $verifiers[$platform] ?? null;

        if (! is_string($class) || $class === '' || ! is_a($class, StoreReceiptVerifier::class, true)) {
            throw $this->unavailable();
        }

        // The fake is a development tool and nothing else. Even a deployment
        // that names it in config gets the retryable refusal in production,
        // because "your store credentials are missing" is a far better failure
        // than "every receipt is accepted".
        if (app()->isProduction() && is_a($class, FakeStoreReceiptVerifier::class, true)) {
            throw $this->unavailable();
        }

        /** @var StoreReceiptVerifier */
        return app($class);
    }

    /**
     * The pack a SKU names, on the platform that named it.
     *
     * `downloadable()` rather than `listable()`: a household re-installing on a
     * new tablet must be able to restore a pack that has since been retired
     * (§7.3).
     */
    public function packForSku(string $platform, string $sku): Pack
    {
        /** @var array<string, string> $columns */
        $columns = config('coloringbook.stores.sku_columns', []);

        $column = $columns[$platform] ?? null;

        if (! is_string($column)) {
            throw $this->unavailable();
        }

        $pack = Pack::query()->downloadable()->where($column, $sku)->first();

        if ($pack === null) {
            // The house 404, not a bespoke code: a SKU nobody sells is exactly
            // "the requested resource does not exist", and inventing a code for
            // it would give a probe a way to enumerate the price list.
            throw new NotFoundHttpException;
        }

        return $pack;
    }

    /**
     * The platforms this build knows the *shape* of, configured or not. Used by
     * the request validator, so an unknown platform is a 422 with a field
     * error rather than a 503 that reads like the server's fault.
     *
     * @return array<int, string>
     */
    public function platforms(): array
    {
        /** @var array<string, string> $columns */
        $columns = config('coloringbook.stores.sku_columns', []);

        return array_keys($columns);
    }

    private function unavailable(): ApiException
    {
        return new ApiException(
            'STORE_UNAVAILABLE',
            __('Purchases cannot be verified right now. Please try again later.'),
            Response::HTTP_SERVICE_UNAVAILABLE,
        );
    }
}
