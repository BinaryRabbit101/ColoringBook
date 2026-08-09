<?php

namespace App\Http\Controllers\Api\V1;

use App\Actions\Entitlements\VerifyStoreReceipt;
use App\Concerns\ResolvesEntitlementOwner;
use App\Http\Controllers\Controller;
use App\Http\Requests\Entitlements\VerifyReceiptRequest;
use App\Http\Resources\EntitlementResource;
use App\Models\Entitlement;
use App\Services\Entitlements;
use App\Services\PackCatalog;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * What this owner owns, and how a purchase becomes a row (DLC_SERVER.md §11,
 * §9, §4.3).
 *
 * **Owner**, not user: since BL-52 both endpoints accept an account token *and*
 * an anonymous device token, and read or write the rows belonging to whichever
 * one the bearer names. The gate is the `entitlements:read` ability, which both
 * kinds of token carry — never the kind of identity behind it.
 *
 * `index` is deliberately one call doing two jobs: the client caches this list
 * for offline play, and comparing each `latest_version` against the version it
 * has installed *is* the update check, folded in rather than costing a second
 * round trip on launch (§7.3).
 *
 * Revoked rows are absent — a refunded pack disappears from the shelf while
 * every pixel a child painted stays on disk (§7.3).
 *
 * `?client_version=` applies here too: an old build is told the newest release
 * **it can run**, so it never tries to install something that needs a newer
 * game.
 */
class EntitlementController extends Controller
{
    use ResolvesEntitlementOwner;

    public function __construct(
        private readonly Entitlements $entitlements,
        private readonly PackCatalog $catalog,
    ) {}

    public function index(Request $request): JsonResponse
    {
        $owner = $this->requireOwner($request);

        /** @var array{client_version?: string} $validated */
        $validated = $request->validate([
            'client_version' => ['sometimes', 'string', 'max:32', 'regex:/^[0-9]+(\.[0-9]+)*$/'],
        ]);

        $clientVersion = $validated['client_version'] ?? null;

        $entitlements = $this->entitlements->live($owner)->map(
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
     * `POST /entitlements/verify` — the restore path (BL-52, §9).
     *
     * The answer is one `EntitlementResource`, the same shape `index` returns a
     * list of, so a client can drop it straight into its cache. Always `200`:
     * verifying a purchase the owner already holds is a legitimate every-launch
     * call, not a conflict.
     */
    public function verify(VerifyReceiptRequest $request, VerifyStoreReceipt $verify): JsonResponse
    {
        $owner = $this->requireOwner($request);

        $entitlement = $verify->handle(
            owner: $owner,
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
