<?php

namespace App\Http\Controllers\Admin;

use App\Actions\Authoring\DeleteAuthoredPage;
use App\Actions\Authoring\StoreAuthoredPage;
use App\Actions\Authoring\UpdateAuthoredPage;
use App\Concerns\ResolvesAuthoredBooks;
use App\Concerns\ResolvesAuthoringAssets;
use App\Concerns\ServesAuthoringImages;
use App\Http\Controllers\Controller;
use App\Http\Requests\Admin\StorePageRequest;
use App\Http\Requests\Admin\UpdatePageRequest;
use App\Http\Resources\AuthoredBookResource;
use App\Http\Resources\AuthoredPageResource;
use App\Models\Asset;
use App\Services\Authoring\AuthoredPagePreview;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\RedirectResponse;
use Inertia\Inertia;
use Inertia\Response as InertiaResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * The page editor (BL-24, §10.3) — session door.
 *
 * The editor is where §10.3's promise is kept: mapping state, the §10.1
 * region-overlay preview, and the validation report in plain language, on one
 * screen, for the page in front of the operator. It shares every action and
 * every FormRequest with the token door.
 *
 * `status` answers JSON rather than an Inertia page on purpose — it is what the
 * editor polls while a mapping job runs, and a full page visit per poll would
 * re-render the book for the sake of one word.
 */
class BookPageController extends Controller
{
    use ResolvesAuthoredBooks, ResolvesAuthoringAssets, ServesAuthoringImages;

    public function show(string $book, int $index): InertiaResponse
    {
        $authored = $this->authoredBook($book, withPages: true);
        $authored->loadMissing('pack.versions');

        return Inertia::render('admin/AuthoredPage', [
            'book' => new AuthoredBookResource($authored),
            'page' => new AuthoredPageResource($this->authoredPage($authored, $index)),
        ]);
    }

    /**
     * Mapping-job state, validation verdict and preview URL — §11's
     * `GET /admin/books/{book_uid}/pages/{index}/status`.
     */
    public function status(string $book, int $index): JsonResponse
    {
        $page = $this->authoredPage($this->authoredBook($book), $index);

        return response()->json(['page' => new AuthoredPageResource($page)]);
    }

    public function store(StorePageRequest $request, string $book, StoreAuthoredPage $store): RedirectResponse
    {
        $authored = $this->authoredBook($book);

        $display = $this->resolveAsset($request, 'display', 'display_asset_ulid', 'display');

        if (! $display instanceof Asset) {
            return back()->withErrors(['display' => __('Choose the page\'s detail image.')]);
        }

        $page = $store->handle(
            $authored,
            $display,
            $this->resolveAsset($request, 'mask', 'mask_asset_ulid', 'mask'),
            $request->filled('title') ? (string) $request->string('title') : null,
            $this->resolveTuning($request),
        );

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Page added — mapping queued.')]);

        return to_route('admin.books.pages.show', ['book' => $book, 'index' => $page->page_index]);
    }

    public function update(UpdatePageRequest $request, string $book, int $index, UpdateAuthoredPage $update): RedirectResponse
    {
        $authored = $this->authoredBook($book);
        $page = $this->authoredPage($authored, $index);

        $updated = $update->handle($page, $this->pageChanges($request));

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Page updated.')]);

        // A reorder moves the page out from under its own URL, so the redirect
        // has to follow it to wherever it landed.
        return to_route('admin.books.pages.show', ['book' => $book, 'index' => $updated->page_index]);
    }

    public function destroy(string $book, int $index, DeleteAuthoredPage $delete): RedirectResponse
    {
        $delete->handle($this->authoredPage($this->authoredBook($book), $index));

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Page removed.')]);

        return to_route('admin.books.show', ['book' => $book]);
    }

    /**
     * The composited overlay itself. A plain `<img src>` target, so it has to
     * be a session-authenticated route rather than the token API's.
     */
    public function preview(string $book, int $index, AuthoredPagePreview $preview): Response
    {
        $page = $this->authoredPage($this->authoredBook($book), $index);

        return response($preview->render($page), Response::HTTP_OK, [
            'Content-Type' => 'image/png',
            'Cache-Control' => 'private, max-age=3600',
        ]);
    }

    /**
     * The page's own detail image (BL-38) — what the restructured book screen
     * puts a thumbnail of beside every row. The region overlay above is a
     * different picture answering a different question; this one is simply
     * "which drawing is this".
     */
    public function display(string $book, int $index): Response
    {
        return $this->artwork($book, $index, mask: false);
    }

    /**
     * The page's masking image, when it has one — a **404 when it does not**,
     * which is a normal page and not an error. The screen shows an empty slot
     * rather than asking.
     */
    public function mask(string $book, int $index): Response
    {
        return $this->artwork($book, $index, mask: true);
    }

    private function artwork(string $book, int $index, bool $mask): Response
    {
        $page = $this->authoredPage($this->authoredBook($book), $index);
        $asset = $mask ? $page->maskAsset : $page->displayAsset;

        abort_if($asset === null, Response::HTTP_NOT_FOUND);

        $bytes = $this->assetBytes($asset);

        abort_if($bytes === null, Response::HTTP_NOT_FOUND);

        return $this->assetImage($asset, $bytes);
    }
}
