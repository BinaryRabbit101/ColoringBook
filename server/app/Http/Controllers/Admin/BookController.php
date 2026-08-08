<?php

namespace App\Http\Controllers\Admin;

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
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Inertia\Inertia;
use Inertia\Response as InertiaResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * Web authoring in the browser (BL-24, §10.3) — the session door.
 *
 * Same actions and same FormRequests as `/api/v1/admin/books/*`; the only
 * difference is what a refusal looks like. The API answers a book that is not
 * ready with a `422` and a list; the browser bounces back to the book with the
 * same list in the session, because an operator with three unmapped pages needs
 * to read all three, not the first one in a red box.
 */
class BookController extends Controller
{
    use ResolvesAuthoredBooks, ResolvesAuthoringAssets, ServesAuthoringImages;

    public function index(): InertiaResponse
    {
        $books = AuthoredBook::query()
            ->with(['pack.versions', 'pages', 'coverAsset'])
            ->orderBy('title')
            ->get();

        return Inertia::render('admin/Books', [
            'books' => $books
                ->map(fn (AuthoredBook $book): AuthoredBookResource => new AuthoredBookResource($book))
                ->all(),
        ]);
    }

    public function show(Request $request, string $book): InertiaResponse
    {
        $authored = $this->authoredBook($book, withPages: true);
        $authored->loadMissing(['pack.versions', 'coverAsset']);

        return Inertia::render('admin/Book', [
            'book' => new AuthoredBookResource($authored, withPages: true),
            // Populated by a refused publish; empty on a plain visit.
            'publishErrors' => $request->session()->get('book_errors', []),
        ]);
    }

    public function store(StoreBookRequest $request, CreateAuthoredBook $create): RedirectResponse
    {
        /** @var array{book_uid: string, title: string, blurb?: string|null, is_free?: bool} $attributes */
        $attributes = $request->validated();

        $book = $create->handle(
            $attributes['book_uid'],
            $attributes['title'],
            $attributes['blurb'] ?? null,
            (bool) ($attributes['is_free'] ?? false),
        );

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Book created.')]);

        return to_route('admin.books.show', ['book' => $book->book_uid]);
    }

    public function update(UpdateBookRequest $request, string $book, UpdateAuthoredBook $update): RedirectResponse
    {
        /** @var array<string, mixed> $validated */
        $validated = $request->validated();

        $update->handle($this->authoredBook($book), $this->bookChanges($request, $validated));

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Book updated.')]);

        return to_route('admin.books.show', ['book' => $book]);
    }

    /**
     * The book's cover art (BL-38). A plain `<img src>` target, so it has to be
     * a session-authenticated route rather than the token API's.
     */
    public function cover(string $book): Response
    {
        $asset = $this->authoredBook($book)->coverAsset;

        abort_if($asset === null, Response::HTTP_NOT_FOUND);

        $bytes = $this->assetBytes($asset);

        abort_if($bytes === null, Response::HTTP_NOT_FOUND);

        return $this->assetImage($asset, $bytes);
    }

    public function destroy(string $book, DeleteAuthoredBook $delete): RedirectResponse
    {
        $outcome = $delete->handle($this->authoredBook($book));

        Inertia::flash('toast', [
            'type' => 'success',
            'message' => $outcome === DeleteAuthoredBook::RETIRED
                // §7.3: delisting must never take a book off a shelf someone
                // already owns.
                ? __('Book removed. Its pack was published, so it was retired rather than deleted — households that own it keep it.')
                : __('Book deleted.'),
        ]);

        return to_route('admin.books.index');
    }

    public function publish(string $book, PublishAuthoredBook $publish): RedirectResponse
    {
        $authored = $this->authoredBook($book);

        try {
            $version = $publish->handle($authored);
        } catch (ApiException $e) {
            /** @var array<int, string> $errors */
            $errors = is_array($e->details['errors'] ?? null) ? $e->details['errors'] : [$e->getMessage()];

            Inertia::flash('toast', ['type' => 'error', 'message' => __('This book is not ready to publish.')]);

            return to_route('admin.books.show', ['book' => $book])
                ->with('book_errors', array_values($errors));
        }

        Inertia::flash('toast', [
            'type' => 'success',
            'message' => __('Published v:version.', ['version' => $version->version]),
        ]);

        return to_route('admin.books.show', ['book' => $book]);
    }
}
