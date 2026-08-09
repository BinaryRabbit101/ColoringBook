<?php

namespace App\Http\Controllers\Api\V1;

use App\Concerns\ResolvesDevice;
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
 * `owned` reflects the bearer device's own claims — which is what makes the
 * shop show "Download" rather than "Buy" on a tablet that has restored its
 * purchases, with nobody ever having signed in to anything.
 */
class PackController extends Controller
{
    use ResolvesDevice;

    public function __construct(
        private readonly PackCatalog $catalog,
        private readonly Entitlements $entitlements,
    ) {}

    public function index(Request $request): JsonResponse
    {
        $clientVersion = $this->clientVersion($request);
        $device = $this->device($request);

        $owned = $device === null ? [] : $this->entitlements->ownedPackIds($device);

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
        $device = $this->device($request);

        $pack = $this->catalog->findListable($slug);
        $pack->load(['books.pages', 'stickerSets.stickers']);

        return response()->json([
            'pack' => new PackResource(
                $pack,
                $this->catalog->latestVersion($pack, $clientVersion),
                $device !== null && $this->entitlements->owns($device, $pack),
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
