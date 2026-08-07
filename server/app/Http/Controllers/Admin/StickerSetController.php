<?php

namespace App\Http\Controllers\Admin;

use App\Actions\Authoring\CreateAuthoredStickerSet;
use App\Actions\Authoring\DeleteAuthoredStickerSet;
use App\Actions\Authoring\PublishAuthoredStickerSet;
use App\Actions\Authoring\UpdateAuthoredStickerSet;
use App\Concerns\ResolvesAuthoredStickerSets;
use App\Exceptions\ApiException;
use App\Http\Controllers\Controller;
use App\Http\Requests\Admin\StoreStickerSetRequest;
use App\Http\Requests\Admin\UpdateStickerSetRequest;
use App\Http\Resources\AuthoredStickerSetResource;
use App\Models\AuthoredStickerSet;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Inertia\Inertia;
use Inertia\Response as InertiaResponse;

/**
 * Sticker-set authoring in the browser (BL-37) — the session door.
 *
 * Same actions and same FormRequests as `/api/v1/admin/sticker-sets/*`; the
 * only difference is what a refusal looks like. The API answers a set that is
 * not ready with a `422` and a list; the browser bounces back to the set with
 * the same list in the session, because an operator with three broken images
 * needs to read all three.
 */
class StickerSetController extends Controller
{
    use ResolvesAuthoredStickerSets;

    public function index(): InertiaResponse
    {
        $sets = AuthoredStickerSet::query()
            ->with(['pack.versions', 'stickers'])
            ->orderBy('sort_order')
            ->orderBy('title')
            ->get();

        return Inertia::render('admin/StickerSets', [
            'stickerSets' => $sets
                ->map(fn (AuthoredStickerSet $set): AuthoredStickerSetResource => new AuthoredStickerSetResource($set))
                ->all(),
        ]);
    }

    public function show(Request $request, string $set): InertiaResponse
    {
        $authored = $this->authoredStickerSet($set, withStickers: true);

        return Inertia::render('admin/StickerSet', [
            'stickerSet' => new AuthoredStickerSetResource($authored, withStickers: true),
            // Populated by a refused publish; empty on a plain visit.
            'publishErrors' => $request->session()->get('sticker_set_errors', []),
        ]);
    }

    public function store(StoreStickerSetRequest $request, CreateAuthoredStickerSet $create): RedirectResponse
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

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Sticker set created.')]);

        return to_route('admin.sticker-sets.show', ['set' => $set->set_uid]);
    }

    public function update(UpdateStickerSetRequest $request, string $set, UpdateAuthoredStickerSet $update): RedirectResponse
    {
        /** @var array{title?: string, blurb?: string|null, is_free?: bool, sort_order?: int} $changes */
        $changes = $request->validated();

        $update->handle($this->authoredStickerSet($set), $changes);

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Sticker set updated.')]);

        return to_route('admin.sticker-sets.show', ['set' => $set]);
    }

    public function destroy(string $set, DeleteAuthoredStickerSet $delete): RedirectResponse
    {
        $outcome = $delete->handle($this->authoredStickerSet($set));

        Inertia::flash('toast', [
            'type' => 'success',
            'message' => $outcome === DeleteAuthoredStickerSet::RETIRED
                // §7.3: delisting must never take content off a device that has
                // it — and a removed sticker set would empty pages that are
                // already coloured.
                ? __('Sticker set removed. Its pack was published, so it was retired rather than deleted — households that own it keep it.')
                : __('Sticker set deleted.'),
        ]);

        return to_route('admin.sticker-sets.index');
    }

    public function publish(string $set, PublishAuthoredStickerSet $publish): RedirectResponse
    {
        $authored = $this->authoredStickerSet($set);

        try {
            $version = $publish->handle($authored);
        } catch (ApiException $e) {
            /** @var array<int, string> $errors */
            $errors = is_array($e->details['errors'] ?? null) ? $e->details['errors'] : [$e->getMessage()];

            Inertia::flash('toast', ['type' => 'error', 'message' => __('This sticker set is not ready to publish.')]);

            return to_route('admin.sticker-sets.show', ['set' => $set])
                ->with('sticker_set_errors', array_values($errors));
        }

        Inertia::flash('toast', [
            'type' => 'success',
            'message' => __('Published v:version.', ['version' => $version->version]),
        ]);

        return to_route('admin.sticker-sets.show', ['set' => $set]);
    }
}
