<?php

namespace App\Http\Controllers\Api\V1\Admin;

use App\Actions\Authoring\CreateAuthoredBook;
use App\Actions\Authoring\DeleteAuthoredBook;
use App\Actions\Authoring\PublishAuthoredBook;
use App\Actions\Authoring\UpdateAuthoredBook;
use App\Concerns\ResolvesAuthoredBooks;
use App\Concerns\ResolvesAuthoringAssets;
use App\Concerns\ServesAuthoringImages;
use App\Exceptions\ApiException;
use App\Http\Controllers\Controller;
use App\Http\Requests\Admin\StoreBookRequest;
use App\Http\Requests\Admin\UpdateBookRequest;
use App\Http\Resources\AuthoredBookResource;
use App\Models\AuthoredBook;
use Illuminate\Http\JsonResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * The token door onto book authoring (BL-24, §11's web-authoring table).
 *
 * Same actions and same FormRequests as the Inertia controller beside it —
 * the WP5 pattern, and the reason the browser and a script can never drift
 * apart on what a valid book is.
 */
class BookController extends Controller
{
    use ResolvesAuthoredBooks, ResolvesAuthoringAssets, ServesAuthoringImages;

    private const ROUTE_PREFIX = 'api.v1.admin.';

    public function index(): JsonResponse
    {
        $books = AuthoredBook::query()
            ->with(['pack.versions', 'pages', 'coverAsset'])
            ->orderBy('title')
            ->get();

        return response()->json([
            'books' => $books
                ->map(fn (AuthoredBook $book): array => (new AuthoredBookResource($book, false, self::ROUTE_PREFIX))
                    ->toArray(request()))
                ->all(),
        ]);
    }

    public function show(string $book): JsonResponse
    {
        return response()->json([
            'book' => new AuthoredBookResource($this->authoredBook($book, withPages: true), true, self::ROUTE_PREFIX),
        ]);
    }

    public function store(StoreBookRequest $request, CreateAuthoredBook $create): JsonResponse
    {
        /** @var array{book_uid: string, title: string, blurb?: string|null, is_free?: bool} $attributes */
        $attributes = $request->validated();

        $book = $create->handle(
            $attributes['book_uid'],
            $attributes['title'],
            $attributes['blurb'] ?? null,
            (bool) ($attributes['is_free'] ?? false),
        );

        return response()->json(
            ['book' => new AuthoredBookResource($book, false, self::ROUTE_PREFIX)],
            Response::HTTP_CREATED,
        );
    }

    public function update(UpdateBookRequest $request, string $book, UpdateAuthoredBook $update): JsonResponse
    {
        /** @var array<string, mixed> $validated */
        $validated = $request->validated();

        $updated = $update->handle($this->authoredBook($book), $this->bookChanges($request, $validated));

        return response()->json(['book' => new AuthoredBookResource($updated, false, self::ROUTE_PREFIX)]);
    }

    /**
     * The book's cover art (BL-38), as `image/png`.
     *
     * A book with no cover is a **404, not an empty response**: the fallback to
     * page one's art is the publisher's job and the game's, not this route's,
     * and an authoring screen showing an empty cover slot has to be able to
     * tell "no cover" from "a cover that failed to load".
     */
    public function cover(string $book): Response
    {
        $asset = $this->authoredBook($book)->coverAsset;
        $bytes = $asset === null ? null : $this->assetBytes($asset);

        if ($asset === null || $bytes === null) {
            throw new ApiException(
                'COVER_NOT_FOUND',
                __('That book has no cover image.'),
                Response::HTTP_NOT_FOUND,
            );
        }

        return $this->assetImage($asset, $bytes);
    }

    public function destroy(string $book, DeleteAuthoredBook $delete): JsonResponse
    {
        return response()->json(['outcome' => $delete->handle($this->authoredBook($book))]);
    }

    /**
     * The one button (§10.3). Refusals come back as
     * `422 BOOK_NOT_PUBLISHABLE` with every reason in `details.errors`, the
     * same shape the pack-upload door uses for a failed validation.
     */
    public function publish(string $book, PublishAuthoredBook $publish): JsonResponse
    {
        $version = $publish->handle($this->authoredBook($book));

        return response()->json([
            'pack_slug' => $version->pack->slug,
            'version' => $version->version,
            'status' => 'published',
            'published_at' => $version->published_at?->toIso8601String(),
        ], Response::HTTP_CREATED);
    }
}
