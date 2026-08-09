<?php

namespace App\Http\Controllers\Api\V1;

use App\Concerns\ResolvesEntitlementOwner;
use App\Exceptions\ApiException;
use App\Http\Controllers\Controller;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Services\Entitlements;
use App\Services\PackCatalog;
use App\Services\PackManifest;
use App\Services\PrivateDownloads;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Laravel\Sanctum\Exceptions\MissingAbilityException;
use Symfony\Component\HttpFoundation\Response;

/**
 * Getting a pack's bytes onto a device (DLC_SERVER.md §7.4, §11).
 *
 * Two halves, and they are separate on purpose:
 *
 * - `manifest`, `download` and `file` are the **authorising** half. They send
 *   no bytes; `download`/`file` answer `302` with a ten-minute signed URL.
 * - `archive` and `deltaFile` are the **signed** half: no token at all, the
 *   signature is the authorisation. This is what lets Godot's
 *   `HTTPRequest.download_file` stream an 8 MB pack straight into
 *   `user://dlc/<slug>.incoming/` without minding auth headers.
 *
 * ## Free packs are public (BL-52, §7.4)
 *
 * The first half used to be flatly `auth:sanctum` + `abilities:packs:download`
 * + entitlement. It is now **optional auth**, and the gate depends on the pack:
 *
 * - `is_free` and downloadable → allowed, with or without a token. A signed-out
 *   child on a fresh tablet can browse the shop and download every free book,
 *   which is the whole point. When a token *is* present the free-claim still
 *   fires, so `owned` and `GET /entitlements` keep meaning what they mean.
 * - anything else → exactly what it was: token, ability, live entitlement.
 *
 * The 302-to-signed-URL mechanics did not move a byte. The signature was always
 * the thing that authorises the transfer; what changed is who may ask for one.
 *
 * Retired packs stay fetchable throughout: delisting a pack must never take
 * away books a household already owns (§7.3).
 */
class PackDownloadController extends Controller
{
    use ResolvesEntitlementOwner;

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
     * Decide whether this request may name these bytes, then resolve
     * `?version=`.
     *
     * @return array{0: Pack, 1: PackVersion}
     */
    private function authorised(Request $request, string $slug): array
    {
        $pack = $this->catalog->findDownloadable($slug);
        $owner = $this->owner($request);

        if ($pack->is_free) {
            // Public (BL-52). A token is welcome but not required; when one is
            // here the pack claims itself, exactly as it did before, so the
            // shop's `owned` flag and `GET /entitlements` stay honest for
            // signed-in households. A **revoked** row is left revoked — the
            // claim only ever fires when there is no row at all — and it does
            // not block the download, because revocation governs the row, not
            // whether a free pack is public.
            if ($owner !== null) {
                $this->entitlements->claimFree($owner, $pack);
            }
        } else {
            abort_if($owner === null, Response::HTTP_UNAUTHORIZED);

            // The ability gate used to be route middleware. Optional auth moved
            // it in here, where it can apply to paid packs only; the failure is
            // byte-identical (`403 MISSING_ABILITY`) because it is the same
            // exception the middleware throws.
            if ($request->user()?->tokenCan('packs:download') !== true) {
                throw new MissingAbilityException(['packs:download']);
            }

            $this->entitlements->authorise($owner, $pack);
        }

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
