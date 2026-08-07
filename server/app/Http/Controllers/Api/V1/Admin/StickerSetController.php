<?php

namespace App\Http\Controllers\Api\V1\Admin;

use App\Actions\Authoring\CreateAuthoredStickerSet;
use App\Actions\Authoring\DeleteAuthoredStickerSet;
use App\Actions\Authoring\PublishAuthoredStickerSet;
use App\Actions\Authoring\UpdateAuthoredStickerSet;
use App\Concerns\ResolvesAuthoredStickerSets;
use App\Http\Controllers\Controller;
use App\Http\Requests\Admin\StoreStickerSetRequest;
use App\Http\Requests\Admin\UpdateStickerSetRequest;
use App\Http\Resources\AuthoredStickerSetResource;
use App\Models\AuthoredStickerSet;
use Illuminate\Http\JsonResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * The token door onto sticker-set authoring (BL-37).
 *
 * Same actions and same FormRequests as the Inertia controller beside it — the
 * WP5/WP14 pattern, and the reason the browser and a script can never drift
 * apart on what a valid sticker set is.
 */
class StickerSetController extends Controller
{
    use ResolvesAuthoredStickerSets;

    private const ROUTE_PREFIX = 'api.v1.admin.';

    public function index(): JsonResponse
    {
        $sets = AuthoredStickerSet::query()
            ->with(['pack.versions', 'stickers'])
            ->orderBy('sort_order')
            ->orderBy('title')
            ->get();

        return response()->json([
            'sticker_sets' => $sets
                ->map(fn (AuthoredStickerSet $set): array => (new AuthoredStickerSetResource($set, false, self::ROUTE_PREFIX))
                    ->toArray(request()))
                ->all(),
        ]);
    }

    public function show(string $set): JsonResponse
    {
        return response()->json([
            'sticker_set' => new AuthoredStickerSetResource(
                $this->authoredStickerSet($set, withStickers: true), true, self::ROUTE_PREFIX,
            ),
        ]);
    }

    public function store(StoreStickerSetRequest $request, CreateAuthoredStickerSet $create): JsonResponse
    {
        /** @var array{set_uid: string, title: string, blurb?: string|null, is_free?: bool, sort_order?: int} $attributes */
        $attributes = $request->validated();

        $set = $create->handle(
            $attributes['set_uid'],
            $attributes['title'],
            $attributes['blurb'] ?? null,
            (bool) ($attributes['is_free'] ?? false),
            (int) ($attributes['sort_order'] ?? 100),
        );

        return response()->json(
            ['sticker_set' => new AuthoredStickerSetResource($set, false, self::ROUTE_PREFIX)],
            Response::HTTP_CREATED,
        );
    }

    public function update(UpdateStickerSetRequest $request, string $set, UpdateAuthoredStickerSet $update): JsonResponse
    {
        /** @var array{title?: string, blurb?: string|null, is_free?: bool, sort_order?: int} $changes */
        $changes = $request->validated();

        $updated = $update->handle($this->authoredStickerSet($set), $changes);

        return response()->json([
            'sticker_set' => new AuthoredStickerSetResource($updated, false, self::ROUTE_PREFIX),
        ]);
    }

    public function destroy(string $set, DeleteAuthoredStickerSet $delete): JsonResponse
    {
        return response()->json(['outcome' => $delete->handle($this->authoredStickerSet($set))]);
    }

    /**
     * The one button (BL-37). Refusals come back as
     * `422 STICKER_SET_NOT_PUBLISHABLE` with every reason in `details.errors`,
     * the same shape the book publisher and the pack-upload door use.
     */
    public function publish(string $set, PublishAuthoredStickerSet $publish): JsonResponse
    {
        $version = $publish->handle($this->authoredStickerSet($set));

        return response()->json([
            'pack_slug' => $version->pack->slug,
            'kind' => $version->pack->kind,
            'version' => $version->version,
            'status' => 'published',
            'published_at' => $version->published_at?->toIso8601String(),
        ], Response::HTTP_CREATED);
    }
}
