<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Http\Resources\EntitlementResource;
use App\Models\Entitlement;
use App\Models\User;
use App\Services\Entitlements;
use App\Services\PackCatalog;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * `GET /entitlements` — what this account owns, and what the newest release
 * of each of those packs is (DLC_SERVER.md §11).
 *
 * Deliberately one call doing two jobs: the client caches this list for
 * offline play, and comparing each `latest_version` against the version it
 * has installed *is* the update check, folded in rather than costing a second
 * round trip on launch (§7.3).
 *
 * Revoked rows are absent — a refunded pack disappears from the shelf while
 * every pixel a child painted stays on disk (§7.3).
 *
 * `?client_version=` applies here too: an old build is told the newest
 * release **it can run**, so it never tries to install something that needs a
 * newer game.
 */
class EntitlementController extends Controller
{
    public function __construct(
        private readonly Entitlements $entitlements,
        private readonly PackCatalog $catalog,
    ) {}

    public function __invoke(Request $request): JsonResponse
    {
        $user = $request->user();

        abort_unless($user instanceof User, Response::HTTP_UNAUTHORIZED);

        /** @var array{client_version?: string} $validated */
        $validated = $request->validate([
            'client_version' => ['sometimes', 'string', 'max:32', 'regex:/^[0-9]+(\.[0-9]+)*$/'],
        ]);

        $clientVersion = $validated['client_version'] ?? null;

        $entitlements = $this->entitlements->live($user)->map(
            fn (Entitlement $entitlement): EntitlementResource => new EntitlementResource(
                $entitlement,
                $this->catalog->latestVersion($entitlement->pack, $clientVersion)?->version,
            ),
        );

        // A bare array, exactly as §11 writes it: [{pack_slug, …}].
        // `JsonResource::withoutWrapping()` keeps it that way.
        return response()->json($entitlements->all());
    }
}
