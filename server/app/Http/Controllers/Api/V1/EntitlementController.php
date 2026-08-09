<?php

namespace App\Http\Controllers\Api\V1;

use App\Actions\Entitlements\VerifyStoreReceipt;
use App\Concerns\ResolvesDevice;
use App\Http\Controllers\Controller;
use App\Http\Requests\Entitlements\VerifyReceiptRequest;
use App\Http\Resources\EntitlementResource;
use App\Models\Entitlement;
use App\Services\Entitlements;
use App\Services\PackCatalog;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * What this device owns, and how a purchase becomes a row (DLC_SERVER.md §11,
 * §9, §4.3).
 *
 * The bearer is always the device its token was minted on, and these two
 * endpoints read and write that device's rows. The gate is the
 * `entitlements:read` ability, never the kind of identity behind it.
 *
 * `index` is deliberately one call doing two jobs: the client caches this list
 * for offline play, and comparing each `latest_version` against the version it
 * has installed *is* the update check, folded in rather than costing a second
 * round trip on launch (§7.3).
 *
 * Revoked rows are absent — a refunded pack disappears from the shelf while
 * every pixel a child painted stays on the tablet (§7.3).
 *
 * `?client_version=` applies here too: an old build is told the newest release
 * **it can run**, so it never tries to install something that needs a newer
 * game.
 */
class EntitlementController extends Controller
{
    use ResolvesDevice;

    public function __construct(
        private readonly Entitlements $entitlements,
        private readonly PackCatalog $catalog,
    ) {}

    public function index(Request $request): JsonResponse
    {
        $device = $this->requireDevice($request);

        /** @var array{client_version?: string} $validated */
        $validated = $request->validate([
            'client_version' => ['sometimes', 'string', 'max:32', 'regex:/^[0-9]+(\.[0-9]+)*$/'],
        ]);

        $clientVersion = $validated['client_version'] ?? null;

        $entitlements = $this->entitlements->live($device)->map(
            fn (Entitlement $entitlement): EntitlementResource => new EntitlementResource(
                $entitlement,
                $this->catalog->latestVersion($entitlement->pack, $clientVersion)?->version,
            ),
        );

        // A bare array, exactly as §11 writes it: [{pack_slug, …}].
        // `JsonResource::withoutWrapping()` keeps it that way.
        return response()->json($entitlements->all());
    }

    /**
     * `POST /entitlements/verify` — the restore path (§9).
     *
     * The answer is one `EntitlementResource`, the same shape `index` returns a
     * list of, so a client can drop it straight into its cache. Always `200`:
     * verifying a purchase the device already holds is a legitimate every-launch
     * call, not a conflict.
     */
    public function verify(VerifyReceiptRequest $request, VerifyStoreReceipt $verify): JsonResponse
    {
        $device = $this->requireDevice($request);

        $entitlement = $verify->handle(
            device: $device,
            platform: $request->string('platform')->toString(),
            purchaseToken: $request->string('purchase_token')->toString(),
            sku: $request->string('sku')->toString(),
        );

        return response()->json(new EntitlementResource(
            $entitlement->load('pack'),
            $this->catalog->latestVersion($entitlement->pack)?->version,
        ));
    }
}
