<?php

namespace App\Concerns;

use App\Models\AuthoredBook;
use App\Models\AuthoredPage;

/**
 * Resolving `{book_uid}` and `{index}` the same way behind both admin doors
 * (BL-24, §11's web-authoring table).
 *
 * A page is addressed by its **index within its book**, not by an id: that is
 * what §11 specifies, it is what the operator sees, and it means a URL keeps
 * meaning the same thing after a reorder — which is the correct behaviour for a
 * page list you are rearranging.
 *
 * Everything here `firstOrFail()`s, which the two doors then render
 * differently: `404 NOT_FOUND` in the house error shape for the API, a plain
 * 404 page for the browser.
 */
trait ResolvesAuthoredBooks
{
    protected function authoredBook(string $bookUid, bool $withPages = false): AuthoredBook
    {
        $query = AuthoredBook::query()->where('book_uid', $bookUid)->with('pack');

        if ($withPages) {
            $query->with(['pages.displayAsset', 'pages.maskAsset', 'pages.idmapAsset']);
        }

        /** @var AuthoredBook */
        return $query->firstOrFail();
    }

    protected function authoredPage(AuthoredBook $book, int $index): AuthoredPage
    {
        /** @var AuthoredPage */
        return $book->pages()
            ->where('page_index', $index)
            ->with(['displayAsset', 'maskAsset', 'idmapAsset', 'regionsAsset', 'maskArtifactAsset'])
            ->firstOrFail();
    }
}
