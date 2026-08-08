<?php

namespace App\Actions\Authoring;

use App\Actions\Admin\PublishPackVersion;
use App\Actions\Admin\SubmitPackVersion;
use App\Exceptions\ApiException;
use App\Models\Asset;
use App\Models\AuthoredBook;
use App\Models\AuthoredPage;
use App\Models\PackVersion;
use App\Services\Authoring\AuthoringWorkspace;
use App\Services\PackManifest;
use Illuminate\Database\Eloquent\Collection;
use Symfony\Component\HttpFoundation\Response;

/**
 * `POST /admin/books/{book_uid}/publish` — the one button (BL-24, §10.3).
 *
 * It does exactly two things that are not bookkeeping:
 *
 * 1. **It refuses.** While any page is unmapped or failing §10.1, this throws
 *    with the *whole* list of reasons, in the operator's language. A giant
 *    region is not a server problem to route around — it means a line in the
 *    drawing has a gap, and the only fix is the art.
 * 2. **It writes a §7.2 pack directory and hands it to the existing publish
 *    path.** `SubmitPackVersion` (structural + pixel validation, then
 *    `PublishPackDirectory` as a draft) followed by `PublishPackVersion` to
 *    stamp it. There is **no second publisher**: every `pack_versions` row in
 *    this application, from `pack:publish` to the admin zip upload to this
 *    button, comes out of `PublishPackDirectory`, which is what makes "versions
 *    are monotonic per pack and immutable once published" a property of the
 *    system rather than a promise.
 *
 * Validating a second time at publish, over artifacts this server generated and
 * already checked, is not redundancy for its own sake: the assets could have
 * been replaced, pruned or re-mapped since, and the release is immutable the
 * moment it exists. The cheap check goes before the irreversible act.
 *
 * Everything the operator edits after this accumulates as draft state until the
 * button is pressed again — which is then v2, never a rewrite of v1 (§7.3).
 */
class PublishAuthoredBook
{
    public function __construct(
        private readonly AuthoringWorkspace $workspace,
        private readonly SubmitPackVersion $submit,
        private readonly PublishPackVersion $publish,
    ) {}

    /**
     * @throws ApiException when the book is not in a publishable state
     */
    public function handle(AuthoredBook $book): PackVersion
    {
        /** @var Collection<int, AuthoredPage> $pages */
        $pages = $book->pages()->get();

        $blockers = $book->publishBlockers($pages);

        if ($blockers !== []) {
            throw self::refusal($blockers);
        }

        $directory = $this->workspace->create('publish');

        try {
            $manifest = $this->build($book, $pages, $directory);

            file_put_contents(
                $directory.DIRECTORY_SEPARATOR.PackManifest::FILENAME,
                (string) json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE),
            );

            $draft = $this->submit->handle($directory, $book->pack->slug, $book->pack->is_free);

            return $this->publish->handle($draft->version);
        } finally {
            $this->workspace->discard($directory);
        }
    }

    /**
     * Lay the pack out on disk and describe it — §7.2's layout, verbatim:
     *
     * ```
     * books/<book_uid>/cover.png              only when the artist supplied one
     * books/<book_uid>/page_01.png            the display image
     * books/<book_uid>/page_01_mask.png       only when the page has a mask
     * books/<book_uid>/page_01_idmap.png
     * books/<book_uid>/page_01_regions.json
     * ```
     *
     * ## The cover (BL-38)
     *
     * The pack cover and the book cover are the same path and there are two
     * things it can be:
     *
     * 1. **The artist's cover image**, when the book has one — shipped as
     *    `books/<book_uid>/cover.png` and named by both `cover` fields. This is
     *    what the game's bookshelf grid and the book open/close animation want:
     *    art drawn to be a cover rather than a page that happens to be first.
     * 2. **Page one's display art**, when it does not — which is exactly what
     *    every book published before BL-38 shipped, so old packs stay valid and
     *    a book nobody has drawn a cover for publishes the pack it always did.
     *
     * `cover` is therefore never absent from a manifest this publisher writes;
     * the *optionality* lives on the authored row. The game's own "no cover ⇒
     * fall back to the first page" rule is the third layer, for a pack built
     * some other way.
     *
     * @param  Collection<int, AuthoredPage>  $pages
     * @return array<string, mixed>
     */
    private function build(AuthoredBook $book, Collection $pages, string $directory): array
    {
        $files = [];
        $manifestPages = [];
        $cover = $this->placeCover($book, $directory, $files);

        foreach ($pages as $page) {
            $stem = sprintf('books/%s/%s', $book->book_uid, $page->fileStem());

            $display = $this->place($page, 'displayAsset', $stem.'.png', $directory, $files);
            $idmap = $this->place($page, 'idmapAsset', $stem.'_idmap.png', $directory, $files);
            $regions = $this->place($page, 'regionsAsset', $stem.'_regions.json', $directory, $files);

            $cover ??= $display;

            $entry = [
                'page_index' => $page->page_index,
                'title' => $page->title,
                'display' => $display,
                'idmap' => $idmap,
                'regions' => $regions,
                'image_size' => [(int) $page->image_w, (int) $page->image_h],
                'region_count' => (int) $page->region_count,
            ];

            // BL-12: the shipped mask is the pipeline's display-resolution
            // resample, never the artist's print-size original.
            if ($page->mask_artifact_asset_id !== null) {
                $entry['mask'] = $this->place($page, 'maskArtifactAsset', $stem.'_mask.png', $directory, $files);
            }

            $manifestPages[] = $entry;
        }

        return [
            'manifest_version' => (int) config('coloringbook.packs.manifest_version'),
            'pack_slug' => $book->pack->slug,
            'title' => $book->pack->title,
            'blurb' => $book->blurb,
            'cover' => $cover,
            'is_free' => $book->pack->is_free,
            'min_client_version' => (string) config('coloringbook.packs.default_min_client_version'),
            'books' => [[
                'book_uid' => $book->book_uid,
                'title' => $book->title,
                'cover' => $cover,
                'pages' => $manifestPages,
            ]],
            'files' => $files,
        ];
    }

    /**
     * The artist's cover art, laid into the pack (BL-38) — or null when the
     * book has none, which is the case the caller falls back from.
     *
     * A missing blob is a **refusal, not a silent fallback**: the operator
     * uploaded a cover and would otherwise be shown a published pack wearing
     * page one, with nothing anywhere saying why.
     *
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     */
    private function placeCover(AuthoredBook $book, string $directory, array &$files): ?string
    {
        $asset = $book->coverAsset;

        if ($asset === null) {
            return null;
        }

        $path = sprintf('books/%s/cover.png', $book->book_uid);
        $target = $directory.DIRECTORY_SEPARATOR.str_replace('/', DIRECTORY_SEPARATOR, $path);

        if (! $this->workspace->materialise($asset, $target)) {
            throw self::refusal([__('The cover image is no longer on disk — upload it again, or remove it.')]);
        }

        $files[$path] = [
            'bytes' => (int) filesize($target),
            'sha256' => (string) hash_file('sha256', $target),
        ];

        return $path;
    }

    /**
     * Materialise one asset into the pack directory and record its digest.
     *
     * The `{bytes, sha256}` pair is measured from the file that was just
     * written rather than copied off the `assets` row, so the manifest
     * describes what is actually in the directory. `PackManifestValidator`
     * re-checks both — and it has caught the difference before.
     *
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     */
    private function place(
        AuthoredPage $page,
        string $relation,
        string $path,
        string $directory,
        array &$files,
    ): string {
        /** @var Asset|null $asset */
        $asset = $page->{$relation};

        if ($asset === null) {
            throw self::refusal([sprintf('%s: %s', $page->label(), __('an artifact is missing — re-map the page.'))]);
        }

        $target = $directory.DIRECTORY_SEPARATOR.str_replace('/', DIRECTORY_SEPARATOR, $path);

        if (! $this->workspace->materialise($asset, $target)) {
            throw self::refusal([sprintf('%s: %s', $page->label(), __('an artifact is no longer on disk — re-map the page.'))]);
        }

        $files[$path] = [
            'bytes' => (int) filesize($target),
            'sha256' => (string) hash_file('sha256', $target),
        ];

        return $path;
    }

    /**
     * The house error shape, carrying every reason at once — the same
     * `{errors, warnings}` `details` block the pack-upload door answers with,
     * so the browser and the API render one thing.
     *
     * @param  array<int, string>  $errors
     */
    public static function refusal(array $errors): ApiException
    {
        return new ApiException(
            'BOOK_NOT_PUBLISHABLE',
            __('This book is not ready to publish.'),
            Response::HTTP_UNPROCESSABLE_ENTITY,
            ['errors' => array_values($errors), 'warnings' => []],
        );
    }
}
