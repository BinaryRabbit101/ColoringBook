<?php

namespace App\Http\Controllers\Admin;

use App\Actions\Admin\GrantPackEntitlement;
use App\Exceptions\ApiException;
use App\Http\Controllers\Controller;
use App\Http\Requests\Admin\GrantEntitlementRequest;
use App\Models\Entitlement;
use App\Models\Pack;
use Illuminate\Http\RedirectResponse;
use Inertia\Inertia;
use Inertia\Response as InertiaResponse;

/**
 * The gift desk: `/admin/entitlements`.
 *
 * The only way a paid pack reaches a player without a store receipt, so the
 * page shows the most recent claims as well as the form — the question after
 * granting one is always "did that land on the right device".
 *
 * A missing device or slug comes back as a **field error**, not a red banner:
 * the operator mistyped one of two inputs and the form should say which.
 */
class EntitlementController extends Controller
{
    private const RECENT = 25;

    public function index(): InertiaResponse
    {
        $entitlements = Entitlement::query()
            ->with(['device', 'pack'])
            ->orderByDesc('granted_at')
            ->orderByDesc('id')
            ->limit(self::RECENT)
            ->get();

        return Inertia::render('admin/Entitlements', [
            'packs' => Pack::query()
                ->orderBy('title')
                ->get()
                ->map(fn (Pack $pack): array => [
                    'slug' => $pack->slug,
                    'title' => $pack->title,
                    'status' => $pack->status,
                ])->all(),
            'entitlements' => $entitlements->map(fn (Entitlement $entitlement): array => [
                'device_uid' => $entitlement->device->device_uid,
                'device_name' => $entitlement->device->device_name,
                'pack_slug' => $entitlement->pack->slug,
                'source' => $entitlement->source,
                'granted_at' => $entitlement->granted_at->toIso8601String(),
                'revoked_at' => $entitlement->revoked_at?->toIso8601String(),
            ])->all(),
            'sources' => [
                Entitlement::SOURCE_PROMO,
                Entitlement::SOURCE_GIFT,
                Entitlement::SOURCE_ADMIN,
            ],
        ]);
    }

    public function store(GrantEntitlementRequest $request, GrantPackEntitlement $grant): RedirectResponse
    {
        try {
            $grant->handle(
                (string) $request->string('device_uid'),
                (string) $request->string('pack_slug'),
                (string) ($request->string('source')->toString() ?: Entitlement::SOURCE_PROMO),
            );
        } catch (ApiException $e) {
            $field = $e->errorCode === 'PACK_NOT_FOUND' ? 'pack_slug' : 'device_uid';

            return back()->withErrors([$field => $e->getMessage()]);
        }

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Entitlement granted.')]);

        return to_route('admin.entitlements.index');
    }
}
