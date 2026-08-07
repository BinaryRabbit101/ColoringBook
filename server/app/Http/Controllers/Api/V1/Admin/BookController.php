<?php

namespace App\Http\Controllers\Api\V1\Admin;

use App\Actions\Authoring\CreateAuthoredBook;
use App\Actions\Authoring\DeleteAuthoredBook;
use App\Actions\Authoring\PublishAuthoredBook;
use App\Actions\Authoring\UpdateAuthoredBook;
use App\Concerns\ResolvesAuthoredBooks;
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
    use ResolvesAuthoredBooks;

    private const ROUTE_PREFIX = 'api.v1.admin.';

    public function index(): JsonResponse
    {
        $books = AuthoredBook::query()
            ->with(['pack.versions', 'pages'])
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
        /** @var array{title?: string, blurb?: string|null, is_free?: bool} $changes */
        $changes = $request->validated();

        $updated = $update->handle($this->authoredBook($book), $changes);

        return response()->json(['book' => new AuthoredBookResource($updated, false, self::ROUTE_PREFIX)]);
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
