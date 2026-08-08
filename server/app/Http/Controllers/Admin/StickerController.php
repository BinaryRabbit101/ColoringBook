<?php

namespace App\Http\Controllers\Admin;

use App\Actions\Authoring\DeleteAuthoredSticker;
use App\Actions\Authoring\StoreAuthoredSticker;
use App\Actions\Authoring\UpdateAuthoredSticker;
use App\Concerns\ResolvesAuthoredStickerSets;
use App\Http\Controllers\Controller;
use App\Http\Requests\Admin\StoreStickerRequest;
use App\Http\Requests\Admin\UpdateStickerRequest;
use App\Models\Asset;
use Illuminate\Http\RedirectResponse;
use Illuminate\Support\Facades\Storage;
use Inertia\Inertia;
use Symfony\Component\HttpFoundation\Response;

/**
 * Stickers inside a set (BL-37) — session door.
 *
 * There is no separate editor screen the way a page has one: a sticker is an id
 * and a picture, and the set screen shows every one of them at once, which is
 * how a sticker sheet is actually reviewed. So this controller is the write half
 * plus the `<img src>` route the grid points at.
 */
class StickerController extends Controller
{
    use ResolvesAuthoredStickerSets;

    public function store(StoreStickerRequest $request, string $set, StoreAuthoredSticker $store): RedirectResponse
    {
        $authored = $this->authoredStickerSet($set);

        $image = $this->resolveStickerImage($request);

        if (! $image instanceof Asset) {
            return back()->withErrors(['image' => __('Choose the sticker\'s image.')]);
        }

        $store->handle(
            $authored,
            $image,
            (string) $request->string('sticker_id'),
            $request->filled('title') ? (string) $request->string('title') : null,
            $this->resolveAnim($request),
        );

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Sticker added.')]);

        return to_route('admin.sticker-sets.show', ['set' => $set]);
    }

    public function update(UpdateStickerRequest $request, string $set, int $index, UpdateAuthoredSticker $update): RedirectResponse
    {
        $authored = $this->authoredStickerSet($set);
        $sticker = $this->authoredSticker($authored, $index);

        $changes = $this->stickerChanges($request);

        if (array_key_exists('sticker_id', $changes)
            && $changes['sticker_id'] !== $sticker->sticker_id
            && $authored->pack->versions()->whereNotNull('published_at')->exists()) {
            return back()->withErrors([
                'sticker_id' => __('This set has been published, so a sticker id can no longer change — every sticker a child has already stuck on a page names it.'),
            ]);
        }

        $update->handle($sticker, $changes);

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Sticker updated.')]);

        return to_route('admin.sticker-sets.show', ['set' => $set]);
    }

    public function destroy(string $set, int $index, DeleteAuthoredSticker $delete): RedirectResponse
    {
        $delete->handle($this->authoredSticker($this->authoredStickerSet($set), $index));

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Sticker removed.')]);

        return to_route('admin.sticker-sets.show', ['set' => $set]);
    }

    /**
     * The sticker's own image. A plain `<img src>` target, so it has to be a
     * session-authenticated route rather than the token API's.
     */
    public function image(string $set, int $index): Response
    {
        $sticker = $this->authoredSticker($this->authoredStickerSet($set), $index);
        $asset = $sticker->imageAsset;
        $disk = Storage::disk((string) config('coloringbook.storage.assets_disk'));

        abort_if(! $disk->exists($asset->storage_path), Response::HTTP_NOT_FOUND);

        return response((string) $disk->get($asset->storage_path), Response::HTTP_OK, [
            'Content-Type' => $asset->mime,
            'Cache-Control' => 'private, max-age=3600',
            'ETag' => '"'.$asset->sha256.'"',
        ]);
    }
}
