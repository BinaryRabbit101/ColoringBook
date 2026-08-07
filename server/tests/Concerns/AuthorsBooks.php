<?php

namespace Tests\Concerns;

use App\Models\AuthoredBook;
use App\Models\AuthoredPage;
use App\Services\Mapping\MappingRunner;
use Illuminate\Http\UploadedFile;
use Tests\Support\FakeMappingRunner;

/**
 * The two things a BL-24 test always needs: a mapping pipeline that does not
 * need an engine, and a real PNG to upload.
 *
 * `fakeMapping()` must be called **before** the page is created, because
 * `QUEUE_CONNECTION=sync` in `phpunit.xml` means `MapAuthoredPage::dispatch()`
 * runs the job inline — which is deliberate. A page that came back from an
 * endpoint has really been through the whole staging → run → store → validate
 * path, so the tests assert on the state a mapped page is actually left in
 * rather than on a job having been queued.
 */
trait AuthorsBooks
{
    /**
     * Bind the fake pipeline for this test.
     *
     * @param  string  $case  A `tests/Fixtures/pages/<case>` directory —
     *                        `valid` maps cleanly, `giant-region` maps and then
     *                        fails §10.1, and so on.
     * @param  string|null  $failWith  Make the run itself refuse, the way a
     *                                 pipeline `FAIL:` does.
     */
    protected function fakeMapping(string $case = 'valid', ?string $failWith = null): FakeMappingRunner
    {
        $runner = new FakeMappingRunner($this->pagesFixturePath($case), $failWith);

        app()->instance(MappingRunner::class, $runner);

        return $runner;
    }

    protected function pagesFixturePath(string $case = 'valid'): string
    {
        return dirname(__DIR__).DIRECTORY_SEPARATOR.'Fixtures'
            .DIRECTORY_SEPARATOR.'pages'.DIRECTORY_SEPARATOR.$case;
    }

    /**
     * A real PNG from a page fixture, wrapped as an upload.
     *
     * `$test: true` keeps Symfony from rejecting it for not having come through
     * PHP's upload machinery — the same trick `AdminsPacks::packUpload()` uses.
     */
    protected function pageUpload(string $case = 'valid', string $file = 'page_01.png', string $as = 'page_01.png'): UploadedFile
    {
        return new UploadedFile(
            $this->pagesFixturePath($case).DIRECTORY_SEPARATOR.$file,
            $as,
            'image/png',
            null,
            true,
        );
    }

    /**
     * A book with `$pages` mapped, valid pages — the shape that can publish.
     */
    protected function authorBook(string $bookUid = 'coyote-2026', int $pages = 1, bool $free = true): AuthoredBook
    {
        $this->fakeMapping();

        $this->postJson('/api/v1/admin/books', [
            'book_uid' => $bookUid,
            'title' => 'Coyote',
            'is_free' => $free,
        ])->assertCreated();

        for ($i = 0; $i < $pages; $i++) {
            $this->post("/api/v1/admin/books/{$bookUid}/pages", [
                'display' => $this->pageUpload(),
                'title' => 'Page '.($i + 1),
            ])->assertCreated();
        }

        /** @var AuthoredBook */
        return AuthoredBook::query()->where('book_uid', $bookUid)->sole();
    }

    /**
     * @return list<AuthoredPage>
     */
    protected function pagesOf(AuthoredBook $book): array
    {
        /** @var list<AuthoredPage> */
        return $book->pages()->get()->all();
    }
}
