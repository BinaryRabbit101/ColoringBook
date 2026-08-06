<?php

namespace App\Http\Controllers\Api\V1\Admin;

use App\Actions\Admin\PublishPackVersion;
use App\Actions\Admin\StagePackDirectory;
use App\Actions\Admin\SubmitPackVersion;
use App\Concerns\ResolvesAdminPacks;
use App\Exceptions\PackPublishException;
use App\Http\Controllers\Controller;
use App\Http\Requests\Admin\StorePackRequest;
use App\Http\Requests\Admin\StorePackVersionRequest;
use App\Http\Resources\AdminPackResource;
use App\Http\Resources\AdminPackVersionResource;
use App\Models\Pack;
use App\Services\PackPreview;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\UploadedFile;
use Symfony\Component\HttpFoundation\Response;

/**
 * The admin half of §11: create a pack, submit a version, look at it, publish
 * it.
 *
 * The shape is the flow in §10.2 and the order is not decoration —
 * `draft → preview → publish` exists so that the only thing standing between
 * a bad ID map and a child's tablet is a person who looked at the region
 * overlay.
 */
class PackController extends Controller
{
    use ResolvesAdminPacks;

    public function index(): JsonResponse
    {
        $packs = Pack::query()
            ->with('versions')
            ->orderBy('sort_order')
            ->orderBy('title')
            ->get();

        return response()->json([
            'packs' => $packs->map(fn (Pack $pack): AdminPackResource => new AdminPackResource($pack))->all(),
        ]);
    }

    public function show(string $slug): JsonResponse
    {
        return response()->json([
            'pack' => new AdminPackResource($this->adminPack($slug, withVersions: true), withVersions: true),
        ]);
    }

    /**
     * A pack row with no artwork yet — a reserved slug to hang drafts off.
     */
    public function store(StorePackRequest $request): JsonResponse
    {
        /** @var array{slug: string, title: string, blurb?: string|null, is_free?: bool, sort_order?: int} $attributes */
        $attributes = $request->validated();

        $pack = new Pack;
        $pack->fill($attributes);
        $pack->status = Pack::STATUS_DRAFT;
        $pack->save();

        return response()->json(['pack' => new AdminPackResource($pack)], Response::HTTP_CREATED);
    }

    /**
     * §11's `{version, warnings[], errors[]}`.
     *
     * The success body carries `errors: []` rather than omitting it, so the
     * pack-build script reads the same two keys on both paths; the failure
     * body is the house error shape with the same two lists inside `details`.
     */
    public function storeVersion(
        StorePackVersionRequest $request,
        string $slug,
        StagePackDirectory $stage,
        SubmitPackVersion $submit,
    ): JsonResponse {
        $pack = $this->adminPack($slug);

        /** @var UploadedFile|null $archive */
        $archive = $request->file('archive');

        /** @var array<string, mixed>|null $manifest */
        $manifest = $request->has('manifest') ? $request->array('manifest') : null;

        try {
            $directory = $archive !== null
                ? $stage->fromZip($archive)
                : $stage->fromAssets($manifest ?? [], $this->assetMap($request));
        } catch (PackPublishException $e) {
            // A zip we refused to unpack, or an asset map that doesn't line up
            // with the manifest: the same refusal as any other bad pack.
            throw SubmitPackVersion::rejection($e->errors);
        }

        try {
            $published = $submit->handle($directory, $pack->slug, $this->freeFlag($request));
        } finally {
            $stage->discard($directory);
        }

        return response()->json([
            'version' => $published->version->version,
            'status' => 'draft',
            'warnings' => array_values($published->warnings),
            'errors' => [],
        ], Response::HTTP_CREATED);
    }

    /**
     * The page list a reviewer clicks through. The overlays themselves are
     * separate requests — they are PNGs, and one JSON document carrying a
     * whole pack's worth of base64 art would be unusable.
     */
    public function preview(string $slug, int $version, PackPreview $preview): JsonResponse
    {
        $pack = $this->adminPack($slug);
        $packVersion = $this->adminVersion($pack, $version);

        $pages = array_map(
            fn (array $page): array => [
                ...$page,
                'preview_url' => route('api.v1.admin.packs.versions.preview.page', [
                    'slug' => $pack->slug,
                    'version' => $packVersion->version,
                    'book' => $page['book_uid'],
                    'page' => $page['page_index'],
                ]),
            ],
            $preview->pages($packVersion),
        );

        return response()->json([
            'version' => new AdminPackVersionResource($packVersion),
            'pages' => $pages,
        ]);
    }

    /**
     * One composited region overlay, as `image/png`.
     */
    public function previewPage(
        string $slug,
        int $version,
        string $book,
        int $page,
        PackPreview $preview,
    ): Response {
        $packVersion = $this->adminVersion($this->adminPack($slug), $version);

        return response($preview->render($packVersion, $book, $page), Response::HTTP_OK, [
            'Content-Type' => 'image/png',
            // A release is immutable, so its overlay is too — but it is admin
            // -only art, so keep it out of shared caches.
            'Cache-Control' => 'private, max-age=3600',
        ]);
    }

    public function publish(string $slug, int $version, PublishPackVersion $publish): JsonResponse
    {
        $packVersion = $publish->handle($this->adminVersion($this->adminPack($slug), $version));

        return response()->json(['version' => new AdminPackVersionResource($packVersion)]);
    }

    /**
     * `assets` is `path → asset_ulid`; the request rules already proved every
     * value is a short string.
     *
     * @return array<string, string>
     */
    private function assetMap(Request $request): array
    {
        $map = [];

        /** @var array<array-key, mixed> $assets */
        $assets = $request->array('assets');

        foreach ($assets as $path => $ulid) {
            if (is_string($path) && is_string($ulid)) {
                $map[$path] = $ulid;
            }
        }

        return $map;
    }

    private function freeFlag(Request $request): ?bool
    {
        return $request->has('is_free') && $request->input('is_free') !== null
            ? $request->boolean('is_free')
            : null;
    }
}
