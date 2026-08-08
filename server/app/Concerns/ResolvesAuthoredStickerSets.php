<?php

namespace App\Concerns;

use App\Actions\Admin\StoreUploadedAsset;
use App\Models\Asset;
use App\Models\AuthoredSticker;
use App\Models\AuthoredStickerSet;
use App\Services\StickerAnim;
use Illuminate\Http\Request;
use Illuminate\Http\UploadedFile;

/**
 * Resolving `{set}` and `{index}` the same way behind both admin doors
 * (BL-37) — `ResolvesAuthoredBooks` for sticker sets.
 *
 * A sticker is addressed by its **index within its set**, not by an id, for the
 * reason a page is: it is what the operator sees, and a URL keeps meaning the
 * same thing after a reorder — which is the correct behaviour for a list you
 * are rearranging.
 *
 * Everything here `firstOrFail()`s, which the two doors then render
 * differently: `404 NOT_FOUND` in the house error shape for the API, a plain
 * 404 page for the browser.
 */
trait ResolvesAuthoredStickerSets
{
    protected function authoredStickerSet(string $setUid, bool $withStickers = false): AuthoredStickerSet
    {
        $query = AuthoredStickerSet::query()->where('set_uid', $setUid)->with('pack.versions');

        if ($withStickers) {
            $query->with(['stickers.imageAsset']);
        }

        /** @var AuthoredStickerSet */
        return $query->firstOrFail();
    }

    protected function authoredSticker(AuthoredStickerSet $set, int $index): AuthoredSticker
    {
        /** @var AuthoredSticker */
        return $set->stickers()
            ->where('sticker_index', $index)
            ->with('imageAsset')
            ->firstOrFail();
    }

    /**
     * §11's two ways for art to arrive — a multipart file, or the ULID of an
     * asset already uploaded to `POST /admin/assets` — converged, exactly as
     * `ResolvesAuthoringAssets` converges a page's.
     */
    protected function resolveStickerImage(Request $request): ?Asset
    {
        $file = $request->file('image');

        if ($file instanceof UploadedFile) {
            return app(StoreUploadedAsset::class)->handle($file, 'sticker');
        }

        $ulid = trim((string) $request->input('image_asset_ulid', ''));

        if ($ulid === '') {
            return null;
        }

        /** @var Asset|null */
        return Asset::query()->where('ulid', $ulid)->first();
    }

    /**
     * The edits a sticker `PATCH` body actually asks for. Every key is present
     * only when the request asked for it: three unrelated edits ride this
     * endpoint and a form submitting one must not clear the others.
     *
     * @return array{
     *     title?: string|null,
     *     sticker_id?: string,
     *     sticker_index?: int,
     *     image?: Asset,
     *     anim?: array{hframes: int, vframes: int, frames: int, fps: float}|null,
     * }
     */
    protected function stickerChanges(Request $request): array
    {
        $changes = [];

        if ($request->has('title')) {
            $title = trim((string) $request->string('title'));
            $changes['title'] = $title === '' ? null : $title;
        }

        if ($request->has('sticker_id')) {
            $changes['sticker_id'] = trim((string) $request->string('sticker_id'));
        }

        if ($request->has('sticker_index')) {
            $changes['sticker_index'] = (int) $request->integer('sticker_index');
        }

        $image = $this->resolveStickerImage($request);

        if ($image instanceof Asset) {
            $changes['image'] = $image;
        }

        // BL-38. Present-and-empty means "make it a still sticker again";
        // absent means "leave it alone", which is what the reorder buttons post.
        if ($request->has('anim')) {
            $changes['anim'] = $this->resolveAnim($request);
        }

        return $changes;
    }

    /**
     * The sprite-sheet metadata a body asks for (BL-38), in the manifest's own
     * shape — or null, which is what a still sticker is.
     *
     * @return array{hframes: int, vframes: int, frames: int, fps: float}|null
     */
    protected function resolveAnim(Request $request): ?array
    {
        return StickerAnim::normalise($request->input('anim'));
    }
}
