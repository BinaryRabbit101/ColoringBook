<?php

namespace App\Http\Controllers\Api\V1\Admin;

use App\Actions\Authoring\DeleteAuthoredSticker;
use App\Actions\Authoring\StoreAuthoredSticker;
use App\Actions\Authoring\UpdateAuthoredSticker;
use App\Concerns\ResolvesAuthoredStickerSets;
use App\Exceptions\ApiException;
use App\Http\Controllers\Controller;
use App\Http\Requests\Admin\StoreStickerRequest;
use App\Http\Requests\Admin\UpdateStickerRequest;
use App\Http\Resources\AuthoredStickerResource;
use App\Models\Asset;
use App\Models\AuthoredSticker;
use Illuminate\Http\JsonResponse;
use Illuminate\Support\Facades\Storage;
use Symfony\Component\HttpFoundation\Response;

/**
 * Stickers, behind the token door (BL-37).
 *
 * `{index}` is the sticker's position in its set, 0-based, exactly as a page's
 * is. There is no `status` route and no polling, because there is no job to
 * wait for: `StickerValidation` runs inline on the way in, so a sticker that
 * came back from `store` has already been checked.
 */
class StickerController extends Controller
{
    use ResolvesAuthoredStickerSets;

    private const ROUTE_PREFIX = 'api.v1.admin.';

    public function index(string $set): JsonResponse
    {
        $stickers = $this->authoredStickerSet($set, withStickers: true)->stickers;

        return response()->json([
            'stickers' => $stickers
                ->map(fn (AuthoredSticker $sticker): array => (new AuthoredStickerResource($sticker, self::ROUTE_PREFIX))
                    ->toArray(request()))
                ->all(),
        ]);
    }

    public function show(string $set, int $index): JsonResponse
    {
        $sticker = $this->authoredSticker($this->authoredStickerSet($set), $index);

        return response()->json(['sticker' => new AuthoredStickerResource($sticker, self::ROUTE_PREFIX)]);
    }

    public function store(StoreStickerRequest $request, string $set, StoreAuthoredSticker $store): JsonResponse
    {
        $authored = $this->authoredStickerSet($set);

        $image = $this->resolveStickerImage($request);

        if (! $image instanceof Asset) {
            throw self::missingImage();
        }

        $sticker = $store->handle(
            $authored,
            $image,
            (string) $request->string('sticker_id'),
            $request->filled('title') ? (string) $request->string('title') : null,
        );

        return response()->json(
            ['sticker' => new AuthoredStickerResource($sticker->refresh(), self::ROUTE_PREFIX)],
            Response::HTTP_CREATED,
        );
    }

    public function update(UpdateStickerRequest $request, string $set, int $index, UpdateAuthoredSticker $update): JsonResponse
    {
        $authored = $this->authoredStickerSet($set);
        $sticker = $this->authoredSticker($authored, $index);

        $changes = $this->stickerChanges($request);

        // A published id is named by every placement a child has already made
        // (BL-36's save shape), so it stops being editable the moment a version
        // exists. Silently ignoring the field would be worse than refusing it.
        if (array_key_exists('sticker_id', $changes)
            && $changes['sticker_id'] !== $sticker->sticker_id
            && $authored->pack->versions()->whereNotNull('published_at')->exists()) {
            throw self::frozenId();
        }

        $updated = $update->handle($sticker, $changes);

        return response()->json(['sticker' => new AuthoredStickerResource($updated, self::ROUTE_PREFIX)]);
    }

    public function destroy(string $set, int $index, DeleteAuthoredSticker $delete): JsonResponse
    {
        $delete->handle($this->authoredSticker($this->authoredStickerSet($set), $index));

        return response()->json(null, Response::HTTP_NO_CONTENT);
    }

    /**
     * The sticker's own image, as `image/png` — the editor's preview.
     *
     * There is no compositing step here, unlike a page's region overlay: a
     * sticker IS the picture, and the only useful preview is the file itself.
     */
    public function image(string $set, int $index): Response
    {
        $sticker = $this->authoredSticker($this->authoredStickerSet($set), $index);
        $asset = $sticker->imageAsset;
        $disk = Storage::disk((string) config('coloringbook.storage.assets_disk'));

        if (! $disk->exists($asset->storage_path)) {
            throw new ApiException(
                'STICKER_IMAGE_NOT_FOUND',
                __('That sticker has no image on disk.'),
                Response::HTTP_NOT_FOUND,
            );
        }

        return response((string) $disk->get($asset->storage_path), Response::HTTP_OK, [
            'Content-Type' => $asset->mime,
            // Content-addressed: a replaced image is a different digest, so the
            // URL's meaning changes with it and there is nothing to invalidate.
            'Cache-Control' => 'private, max-age=3600',
            'ETag' => '"'.$asset->sha256.'"',
        ]);
    }

    protected static function missingImage(): ApiException
    {
        return new ApiException(
            'VALIDATION_FAILED',
            __('A sticker needs an image.'),
            Response::HTTP_UNPROCESSABLE_ENTITY,
            ['details' => ['image' => [__('A sticker needs an image.')]]],
        );
    }

    protected static function frozenId(): ApiException
    {
        return new ApiException(
            'STICKER_ID_FROZEN',
            __('This set has been published, so a sticker id can no longer change — every sticker a child has already stuck on a page names it.'),
            Response::HTTP_UNPROCESSABLE_ENTITY,
        );
    }
}
