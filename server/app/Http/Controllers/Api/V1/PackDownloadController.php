<?php

namespace App\Http\Controllers\Api\V1;

use App\Exceptions\ApiException;
use App\Http\Controllers\Controller;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\User;
use App\Services\Entitlements;
use App\Services\PackCatalog;
use App\Services\PackManifest;
use App\Services\PrivateDownloads;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Getting a pack's bytes onto a device (DLC_SERVER.md §7.4, §11).
 *
 * Two halves, and they are separate on purpose:
 *
 * - `manifest`, `download` and `file` are the **authorised** half: bearer
 *   token, `packs:download` ability, live entitlement. They send no bytes.
 *   `download`/`file` answer `302` with a ten-minute signed URL.
 * - `archive` and `deltaFile` are the **signed** half: no token at all, the
 *   signature is the authorisation. This is what lets Godot's
 *   `HTTPRequest.download_file` stream an 8 MB pack straight into
 *   `user://dlc/<slug>.incoming/` without minding auth headers.
 *
 * Retired packs stay fetchable throughout: delisting a pack must never take
 * away books a household already owns (§7.3).
 */
class PackDownloadController extends Controller
{
    public function __construct(
        private readonly PackCatalog $catalog,
        private readonly Entitlements $entitlements,
        private readonly PrivateDownloads $downloads,
    ) {}

    /**
     * The §7.2 manifest, verbatim. The client diffs its `files` map against
     * what it already has to decide between a full download and a delta.
     */
    public function manifest(Request $request, string $slug): JsonResponse
    {
        [, $version] = $this->authorised($request, $slug);

        return response()->json($version->manifest);
    }

    public function download(Request $request, string $slug): RedirectResponse
    {
        [$pack, $version] = $this->authorised($request, $slug);

        return redirect()->away($this->downloads->signedUrl('api.v1.packs.archive', [
            'slug' => $pack->slug,
            'version' => $version->version,
        ]), Response::HTTP_FOUND);
    }

    /**
     * One file out of a release — the delta path. A v3→v4 bump that fixed one
     * page fetches that page, not eight megabytes (§7.2).
     */
    public function file(Request $request, string $slug, string $path): RedirectResponse
    {
        [$pack, $version] = $this->authorised($request, $slug);

        $this->assertServable($version, $path);

        return redirect()->away($this->downloads->signedUrl('api.v1.packs.file.signed', [
            'slug' => $pack->slug,
            'version' => $version->version,
            'path' => $path,
        ]), Response::HTTP_FOUND);
    }

    /**
     * The signed endpoint that actually moves `pack.zip`.
     */
    public function archive(string $slug, int $version): Response
    {
        [$pack, $release] = $this->release($slug, $version);

        return $this->downloads->serve(
            (string) config('coloringbook.storage.packs_disk'),
            $release->archive_path,
            $pack->slug.'-v'.$release->version.'.zip',
            'packs',
            'application/zip',
        );
    }

    /**
     * The signed endpoint that actually moves one delta file.
     */
    public function deltaFile(string $slug, int $version, string $path): Response
    {
        [$pack, $release] = $this->release($slug, $version);

        $this->assertServable($release, $path);

        return $this->downloads->serve(
            (string) config('coloringbook.storage.packs_disk'),
            $release->filePath($pack->slug, $path),
            basename($path),
            'packs',
        );
    }

    /**
     * Token + ability + entitlement, then resolve `?version=`.
     *
     * A free pack grants itself here, on the way through — see
     * `App\Services\Entitlements` for why that is a row and not a special
     * case in the gate.
     *
     * @return array{0: Pack, 1: PackVersion}
     */
    private function authorised(Request $request, string $slug): array
    {
        $user = $request->user();

        abort_unless($user instanceof User, Response::HTTP_UNAUTHORIZED);

        $pack = $this->catalog->findDownloadable($slug);

        $this->entitlements->authorise($user, $pack);

        return [$pack, $this->catalog->versionOrLatest($pack, $this->requestedVersion($request))];
    }

    /**
     * Resolve a *signed* request's pack and version. No entitlement check:
     * the signature already carries the authorisation this server granted ten
     * minutes ago, and re-checking would break a legitimate download that
     * outlives a refund by a few seconds.
     *
     * @return array{0: Pack, 1: PackVersion}
     */
    private function release(string $slug, int $version): array
    {
        $pack = $this->catalog->findDownloadable($slug);

        return [$pack, $this->catalog->versionOrLatest($pack, $version)];
    }

    /**
     * Path-traversal defence, in two layers.
     *
     * The load-bearing one is the allow-list: a path is servable only if it is
     * a key in *this version's* manifest `files` map, which the publisher
     * built from real files it had already hashed. `../../../.env` is not in
     * that map, and neither is anything else.
     *
     * The shape check runs first anyway, because a traversal that somehow got
     * into a manifest should never reach `Storage`.
     */
    private function assertServable(PackVersion $version, string $path): void
    {
        if (! PackManifest::isSafeRelativePath($path) || ! array_key_exists($path, $version->files())) {
            throw new ApiException(
                'FILE_NOT_FOUND',
                __('That file is not part of this pack version.'),
                Response::HTTP_NOT_FOUND,
            );
        }
    }

    private function requestedVersion(Request $request): ?int
    {
        /** @var array{version?: int} $validated */
        $validated = $request->validate([
            'version' => ['sometimes', 'integer', 'min:1'],
        ]);

        return $validated['version'] ?? null;
    }
}
