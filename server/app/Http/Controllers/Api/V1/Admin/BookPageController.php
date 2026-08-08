<?php

namespace App\Http\Controllers\Api\V1\Admin;

use App\Actions\Authoring\DeleteAuthoredPage;
use App\Actions\Authoring\StoreAuthoredPage;
use App\Actions\Authoring\UpdateAuthoredPage;
use App\Concerns\ResolvesAuthoredBooks;
use App\Concerns\ResolvesAuthoringAssets;
use App\Concerns\ServesAuthoringImages;
use App\Exceptions\ApiException;
use App\Http\Controllers\Controller;
use App\Http\Requests\Admin\StorePageRequest;
use App\Http\Requests\Admin\UpdatePageRequest;
use App\Http\Resources\AuthoredPageResource;
use App\Models\Asset;
use App\Models\AuthoredPage;
use App\Services\Authoring\AuthoredPagePreview;
use Illuminate\Http\JsonResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * Pages, behind the token door (BL-24, §11's web-authoring table).
 *
 * `{index}` is the page's position in its book, 0-based, exactly as everywhere
 * else on this API. `status` is split out from `show` because it is the one
 * route the editor polls while a mapping job runs, and a poll should not drag a
 * whole book's worth of asset metadata with it — although in practice they
 * return the same document, because there is nothing about a page worth hiding
 * from the person authoring it.
 */
class BookPageController extends Controller
{
    use ResolvesAuthoredBooks, ResolvesAuthoringAssets, ServesAuthoringImages;

    private const ROUTE_PREFIX = 'api.v1.admin.';

    public function index(string $book): JsonResponse
    {
        $pages = $this->authoredBook($book, withPages: true)->pages;

        return response()->json([
            'pages' => $pages
                ->map(fn (AuthoredPage $page): array => (new AuthoredPageResource($page, self::ROUTE_PREFIX))
                    ->toArray(request()))
                ->all(),
        ]);
    }

    public function show(string $book, int $index): JsonResponse
    {
        $page = $this->authoredPage($this->authoredBook($book), $index);

        return response()->json(['page' => new AuthoredPageResource($page, self::ROUTE_PREFIX)]);
    }

    /**
     * §11's `GET /admin/books/{book_uid}/pages/{index}/status` — mapping-job
     * state, validation verdict, preview URL. What a build script polls after
     * uploading a page.
     */
    public function status(string $book, int $index): JsonResponse
    {
        return $this->show($book, $index);
    }

    public function store(StorePageRequest $request, string $book, StoreAuthoredPage $store): JsonResponse
    {
        $authored = $this->authoredBook($book);

        $display = $this->resolveAsset($request, 'display', 'display_asset_ulid', 'display');

        if (! $display instanceof Asset) {
            throw self::missingDisplay();
        }

        $page = $store->handle(
            $authored,
            $display,
            $this->resolveAsset($request, 'mask', 'mask_asset_ulid', 'mask'),
            $request->filled('title') ? (string) $request->string('title') : null,
            $this->resolveTuning($request),
        );

        return response()->json(
            ['page' => new AuthoredPageResource($page->refresh(), self::ROUTE_PREFIX)],
            Response::HTTP_CREATED,
        );
    }

    public function update(UpdatePageRequest $request, string $book, int $index, UpdateAuthoredPage $update): JsonResponse
    {
        $page = $this->authoredPage($this->authoredBook($book), $index);

        $updated = $update->handle($page, $this->pageChanges($request));

        return response()->json(['page' => new AuthoredPageResource($updated, self::ROUTE_PREFIX)]);
    }

    public function destroy(string $book, int $index, DeleteAuthoredPage $delete): JsonResponse
    {
        $delete->handle($this->authoredPage($this->authoredBook($book), $index));

        return response()->json(null, Response::HTTP_NO_CONTENT);
    }

    /**
     * The region-overlay preview (§10.1) as `image/png`.
     */
    public function preview(string $book, int $index, AuthoredPagePreview $preview): Response
    {
        $page = $this->authoredPage($this->authoredBook($book), $index);

        return response($preview->render($page), Response::HTTP_OK, [
            'Content-Type' => 'image/png',
            // Keyed by the artifacts' digests, so a re-map is a different URL.
            'Cache-Control' => 'private, max-age=3600',
        ]);
    }

    /**
     * The page's own detail image (BL-38) — the thumbnail the restructured book
     * screen shows, and the file itself rather than the region overlay above.
     */
    public function display(string $book, int $index): Response
    {
        return $this->artwork($book, $index, mask: false);
    }

    /**
     * The page's masking image, when it has one. A page with no mask is a
     * normal page, so this is a `404 PAGE_ART_NOT_FOUND` and not an error state
     * anybody has to route around.
     */
    public function mask(string $book, int $index): Response
    {
        return $this->artwork($book, $index, mask: true);
    }

    private function artwork(string $book, int $index, bool $mask): Response
    {
        $page = $this->authoredPage($this->authoredBook($book), $index);
        $asset = $mask ? $page->maskAsset : $page->displayAsset;
        $bytes = $asset === null ? null : $this->assetBytes($asset);

        if ($asset === null || $bytes === null) {
            throw new ApiException(
                'PAGE_ART_NOT_FOUND',
                $mask
                    ? __('That page has no masking image.')
                    : __('That page has no detail image on disk.'),
                Response::HTTP_NOT_FOUND,
            );
        }

        return $this->assetImage($asset, $bytes);
    }

    protected static function missingDisplay(): ApiException
    {
        return new ApiException(
            'VALIDATION_FAILED',
            __('A page needs its detail image.'),
            Response::HTTP_UNPROCESSABLE_ENTITY,
            ['details' => ['display' => [__('A page needs its detail image.')]]],
        );
    }
}
