<?php

namespace App\Http\Controllers\Api\V1;

use App\Concerns\ResolvesEntitlementOwner;
use App\Http\Controllers\Controller;
use App\Http\Resources\PackResource;
use App\Models\Pack;
use App\Services\Entitlements;
use App\Services\PackCatalog;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * The shop window — `GET /packs` and `GET /packs/{slug}` (DLC_SERVER.md §11).
 *
 * Auth is *optional*: the game shows what exists before anyone has signed in,
 * and adds `owned` once a token is present. Nothing on these two routes reveals
 * anything an anonymous client shouldn't see — no storage paths, no version
 * rows that were never published, no draft packs.
 *
 * Since BL-52 the token may name an anonymous device rather than an account
 * (§4.3), and `owned` then reflects that device's own claims — which is what
 * makes the shop show "Download" rather than "Buy" on a tablet that has
 * restored its purchases without anybody signing in.
 */
class PackController extends Controller
{
    use ResolvesEntitlementOwner;

    public function __construct(
        private readonly PackCatalog $catalog,
        private readonly Entitlements $entitlements,
    ) {}

    public function index(Request $request): JsonResponse
    {
        $clientVersion = $this->clientVersion($request);
        $owner = $this->owner($request);

        $owned = $owner === null ? [] : $this->entitlements->ownedPackIds($owner);

        $packs = $this->catalog->listable($clientVersion)->map(
            fn (Pack $pack): PackResource => new PackResource(
                $pack,
                $this->catalog->latestVersion($pack, $clientVersion),
                in_array($pack->id, $owned, true),
            ),
        );

        return response()->json(['packs' => $packs->all()]);
    }

    public function show(Request $request, string $slug): JsonResponse
    {
        $clientVersion = $this->clientVersion($request);
        $owner = $this->owner($request);

        $pack = $this->catalog->findListable($slug);
        $pack->load(['books.pages', 'stickerSets.stickers']);

        return response()->json([
            'pack' => new PackResource(
                $pack,
                $this->catalog->latestVersion($pack, $clientVersion),
                $owner !== null && $this->entitlements->owns($owner, $pack),
                detailed: true,
            ),
        ]);
    }

    /**
     * `?client_version=` — the build asking. Optional; when absent the caller
     * sees the newest release of everything, which is what a browser hitting
     * the API by hand wants (§7.3).
     */
    private function clientVersion(Request $request): ?string
    {
        /** @var array{client_version?: string} $validated */
        $validated = $request->validate([
            'client_version' => ['sometimes', 'string', 'max:32', 'regex:/^[0-9]+(\.[0-9]+)*$/'],
        ]);

        return $validated['client_version'] ?? null;
    }
}
