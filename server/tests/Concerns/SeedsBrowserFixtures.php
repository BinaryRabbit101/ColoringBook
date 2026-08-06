<?php

namespace Tests\Concerns;

use App\Actions\Packs\PublishPackDirectory;
use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\PackVersion;
use App\Models\PaintLayer;
use App\Models\RetainedPaintLayer;
use App\Models\User;
use App\Services\PaintStorage;
use Carbon\CarbonImmutable;

/**
 * Seeding for the browser suite — WP8.
 *
 * The rest of the test suite reaches these states by driving the API
 * ({@see PaintsPages}) or by faking a disk ({@see PublishesPacks}). Neither
 * works here. `Storage::fake()` swaps the disk inside *this* process's
 * container, and the process that will actually be asked for those bytes is
 * the `php artisan serve` the browser is talking to; it would look at the real
 * disk and find nothing. And driving the paint API from a Dusk test would mean
 * `$this->withToken(...)`, which is a request this process handles itself —
 * a different application instance from the one under test.
 *
 * So everything here writes rows and **real files**, into the private tree
 * `.env.dusk.local` moves to `storage/app/private/dusk` and `composer
 * test:dusk` empties before each run.
 */
trait SeedsBrowserFixtures
{
    /**
     * A PNG, as far as anything downstream is concerned: a real 1x1 image with
     * `$variant` appended, so two calls differ in sha256 while both still
     * carry the signature the upload path checks. Same trick as
     * {@see PaintsPages::png()}.
     */
    protected function paintPng(string $variant = ''): string
    {
        $base = base64_decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
            true,
        );

        return ($base === false ? "\x89PNG\r\n\x1a\n" : $base).$variant;
    }

    /**
     * A page that has already lost a last-write-wins race: the evening picture
     * is live, the morning one is retained and restorable.
     *
     * This is the state `settings/pictures` exists to display, and the only
     * state in which it displays anything at all — a page with nothing to
     * restore is deliberately not listed.
     *
     * @return RetainedPaintLayer the older version, the one the button restores
     */
    protected function seedContestedPage(
        User $user,
        string $bookUid = 'coyote-2026',
        int $pageIndex = 0,
        ?ChildProfile $profile = null,
    ): RetainedPaintLayer {
        $storage = app(PaintStorage::class);
        $morning = CarbonImmutable::parse('2026-08-06 09:00:00');

        $progress = BookProgress::factory()
            ->for($user)
            ->create([
                'book_uid' => $bookUid,
                'child_profile_id' => $profile?->id,
            ]);

        $currentPath = $storage->currentPath($progress, $pageIndex);
        $retainedPath = $storage->retainedPath($currentPath, 1);

        // Bytes first: a row whose blob is missing is exactly the broken
        // button this page is supposed to be the cure for.
        $storage->put($currentPath, $this->paintPng('evening'));
        $storage->put($retainedPath, $this->paintPng('morning'));

        $layer = new PaintLayer;
        $layer->book_progress_id = $progress->id;
        $layer->page_index = $pageIndex;
        $layer->sha256 = hash('sha256', $this->paintPng('evening'));
        $layer->bytes = strlen($this->paintPng('evening'));
        $layer->storage_path = $currentPath;
        $layer->revision = 2;
        $layer->client_painted_at = $morning->addHours(9);
        $layer->save();

        $retained = new RetainedPaintLayer;
        $retained->paint_layer_id = $layer->id;
        $retained->sha256 = hash('sha256', $this->paintPng('morning'));
        $retained->bytes = strlen($this->paintPng('morning'));
        $retained->storage_path = $retainedPath;
        $retained->revision = 1;
        $retained->client_painted_at = $morning;
        $retained->retained_at = CarbonImmutable::now();
        $retained->save();

        return $retained;
    }

    /**
     * The WP5 fixture pack, imported as an unpublished draft.
     *
     * Through the real action, for the same reason {@see PublishesPacks} does
     * it that way: the Publish button in the browser is only worth testing
     * against a version that was created the way a version really is created —
     * content-addressed assets, a zip, an unpacked `files/` tree and all.
     */
    protected function seedDraftPack(string $slug = 'meadow-mates'): PackVersion
    {
        return app(PublishPackDirectory::class)
            ->handle($this->browserPackFixturePath(), $slug, true, publishNow: false)
            ->version;
    }

    protected function browserPackFixturePath(string $name = 'meadow-mates'): string
    {
        return dirname(__DIR__).DIRECTORY_SEPARATOR.'Fixtures'
            .DIRECTORY_SEPARATOR.'packs'.DIRECTORY_SEPARATOR.$name;
    }
}
