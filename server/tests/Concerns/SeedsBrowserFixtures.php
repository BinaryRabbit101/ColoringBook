<?php

namespace Tests\Concerns;

use App\Actions\Admin\StoreAssetFile;
use App\Actions\Packs\PublishPackDirectory;
use App\Models\AuthoredBook;
use App\Models\AuthoredPage;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Services\PackValidation;
use App\Services\PageArtifacts;
use Carbon\CarbonImmutable;

/**
 * Seeding for the browser suite — WP8.
 *
 * The rest of the test suite reaches these states by faking a disk
 * ({@see PublishesPacks}). That does not work here: `Storage::fake()` swaps the
 * disk inside *this* process's container, and the process that will actually be
 * asked for those bytes is the `php artisan serve` the browser is talking to;
 * it would look at the real disk and find nothing.
 *
 * So everything here writes rows and **real files**, into the private tree
 * `.env.dusk.local` moves to `storage/app/private/dusk` and `composer
 * test:dusk` empties before each run.
 */
trait SeedsBrowserFixtures
{
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

    /**
     * BL-24 — a web-authored book with one **already-mapped** page.
     *
     * The mapping job cannot run here. It shells out to headless Godot, and the
     * container that would run it belongs to the `php artisan serve` process,
     * not to this one — there is no `MappingRunner` fake to bind. So the page
     * is seeded in the state a finished job leaves it in, with the fixture's
     * artifacts stored as real content-addressed assets on the Dusk disk. That
     * is exactly what the browser suite is here to look at: the editor, the
     * overlay, the verdict and the publish button, not the pipeline.
     *
     * Pass a `$case` of `giant-region` for a page that mapped and still cannot
     * be published — the failure the operator has to be able to read.
     */
    protected function seedAuthoredBook(
        string $bookUid = 'coyote-2026',
        string $title = 'Coyote',
        string $case = 'valid',
        bool $free = true,
    ): AuthoredBook {
        $pack = new Pack;
        $pack->fill(['slug' => $bookUid, 'title' => $title, 'is_free' => $free]);
        $pack->status = Pack::STATUS_DRAFT;
        $pack->save();

        $book = new AuthoredBook;
        $book->fill(['book_uid' => $bookUid, 'title' => $title]);
        $book->pack()->associate($pack);
        $book->save();

        $store = app(StoreAssetFile::class);
        $directory = dirname(__DIR__).DIRECTORY_SEPARATOR.'Fixtures'
            .DIRECTORY_SEPARATOR.'pages'.DIRECTORY_SEPARATOR.$case;

        $display = $store->handle($directory.DIRECTORY_SEPARATOR.'page_01.png', 'display');
        $idmap = $store->handle($directory.DIRECTORY_SEPARATOR.'page_01_idmap.png', 'idmap');
        $regions = $store->handle($directory.DIRECTORY_SEPARATOR.'page_01_regions.json', 'regions');

        $verdict = app(PackValidation::class)->validatePage(new PageArtifacts(
            'Page 1',
            $directory.DIRECTORY_SEPARATOR.'page_01.png',
            $directory.DIRECTORY_SEPARATOR.'page_01_idmap.png',
            $directory.DIRECTORY_SEPARATOR.'page_01_regions.json',
        ));

        /** @var AuthoredPage $page */
        $page = $book->pages()->create([
            'page_index' => 0,
            'title' => 'Coyote at dusk',
            'display_asset_id' => $display->id,
        ]);

        $page->forceFill([
            'idmap_asset_id' => $idmap->id,
            'regions_asset_id' => $regions->id,
            'image_w' => $idmap->width,
            'image_h' => $idmap->height,
            'region_count' => 4,
            'mapping_status' => AuthoredPage::STATUS_MAPPED,
            'mapped_at' => CarbonImmutable::now(),
            'validation_errors' => $verdict->errors,
            'validation_warnings' => $verdict->warnings,
        ])->save();

        return $book;
    }
}
