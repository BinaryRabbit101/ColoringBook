<?php

namespace App\Http\Controllers\Api\V1\Admin;

use App\Actions\Admin\GrantPackEntitlement;
use App\Http\Controllers\Controller;
use App\Http\Requests\Admin\GrantEntitlementRequest;
use App\Models\Entitlement;
use Illuminate\Http\JsonResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * `POST /api/v1/admin/entitlements` — grant a promo or gift claim to a device,
 * and un-revoke one that was withdrawn (DLC_SERVER.md §11).
 *
 * A `201` whether the row was created or brought back, because the operator
 * asked for one thing — "this device owns this pack" — and that is now true.
 * `un_revoked` is reported for the audit trail rather than for branching.
 */
class EntitlementController extends Controller
{
    public function __invoke(GrantEntitlementRequest $request, GrantPackEntitlement $grant): JsonResponse
    {
        $wasRevoked = $this->existingWasRevoked(
            (string) $request->string('device_uid'),
            (string) $request->string('pack_slug'),
        );

        $entitlement = $grant->handle(
            (string) $request->string('device_uid'),
            (string) $request->string('pack_slug'),
            (string) ($request->string('source')->toString() ?: Entitlement::SOURCE_PROMO),
        );

        return response()->json([
            'pack_slug' => $entitlement->pack->slug,
            'device_uid' => $entitlement->device->device_uid,
            'source' => $entitlement->source,
            'granted_at' => $entitlement->granted_at->toIso8601String(),
            'un_revoked' => $wasRevoked,
        ], Response::HTTP_CREATED);
    }

    /**
     * Looked up *before* the grant, because afterwards there is nothing left
     * to tell a re-grant from a fresh one.
     */
    private function existingWasRevoked(string $deviceUid, string $slug): bool
    {
        return Entitlement::query()
            ->whereNotNull('revoked_at')
            ->whereHas('device', fn ($query) => $query->where('device_uid', $deviceUid))
            ->whereHas('pack', fn ($query) => $query->where('slug', $slug))
            ->exists();
    }
}
