<?php

namespace Tests\Feature\Console;

use App\Actions\Packs\PublishPackDirectory;
use App\Exceptions\PackPublishException;
use App\Models\Asset;
use App\Models\Book;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\Page;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\File;
use Illuminate\Support\Facades\Storage;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * `php artisan pack:publish {dir}` — the publisher (DLC_SERVER.md §7.2, §10.2).
 */
class PackPublishTest extends TestCase
{
    use PublishesPacks, RefreshDatabase;

    public function test_it_publishes_a_built_pack_directory(): void
    {
        $this->fakePackStorage();

        $this->artisan('pack:publish', ['dir' => $this->fixturePackPath(), '--free' => true])
            ->assertSuccessful();

        $pack = Pack::query()->sole();

        $this->assertSame('forest-friends', $pack->slug);
        $this->assertSame('Forest Friends', $pack->title);
        $this->assertSame('Two little books about two little animals.', $pack->blurb);
        $this->assertSame('cover.png', $pack->cover_path);
        $this->assertSame(Pack::STATUS_PUBLISHED, $pack->status);
        $this->assertTrue($pack->is_free);

        $this->assertSame(2, Book::query()->count());
        $this->assertSame(3, Page::query()->count());

        $version = PackVersion::query()->sole();
        $this->assertSame(1, $version->version);
        $this->assertNotNull($version->published_at);
        $this->assertSame('0.7.0', $version->min_client_version);
    }

    public function test_it_maps_a_pages_artifacts_onto_content_addressed_assets(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack();

        $book = Book::query()->where('book_uid', 'coyote-2026')->sole();
        $page = $book->pages()->where('page_index', 0)->sole();

        $this->assertSame(8, $page->image_w);
        $this->assertSame(8, $page->image_h);
        $this->assertSame(2, $page->region_count);
        $this->assertSame('Page 1', $page->title);

        // The mask is optional and this fixture has none — the normal case
        // since BL-9/BL-12.
        $this->assertNull($page->mask_asset_id);

        $display = Asset::query()->findOrFail($page->display_asset_id);
        $idmap = Asset::query()->findOrFail($page->idmap_asset_id);
        $regions = Asset::query()->findOrFail($page->regions_asset_id);

        $this->assertSame('display', $display->kind);
        $this->assertSame('idmap', $idmap->kind);
        $this->assertSame('regions', $regions->kind);
        $this->assertSame('image/png', $display->mime);
        $this->assertSame('application/json', $regions->mime);
        $this->assertSame(8, $display->width);
        $this->assertNull($regions->width);

        // assets/<sha256[0:2]>/<sha256> — §5's storage layout, and the bytes
        // really are there under their own digest.
        $disk = Storage::disk((string) config('coloringbook.storage.assets_disk'));

        foreach ([$display, $idmap, $regions] as $asset) {
            $this->assertSame(substr($asset->sha256, 0, 2).'/'.$asset->sha256, $asset->storage_path);
            $disk->assertExists($asset->storage_path);
            $this->assertSame($asset->sha256, hash('sha256', (string) $disk->get($asset->storage_path)));
        }
    }

    public function test_one_file_serving_two_roles_is_one_blob_and_two_rows(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack();

        // The fixture's book covers are page one's display art.
        $book = Book::query()->where('book_uid', 'coyote-2026')->sole();
        $cover = Asset::query()->findOrFail($book->cover_asset_id);
        $display = Asset::query()->findOrFail($book->pages()->where('page_index', 0)->sole()->display_asset_id);

        $this->assertSame('cover', $cover->kind);
        $this->assertSame('display', $display->kind);
        $this->assertNotSame($cover->id, $display->id);
        $this->assertSame($cover->sha256, $display->sha256);
        $this->assertSame($cover->storage_path, $display->storage_path);
    }

    public function test_it_writes_the_zip_and_the_unpacked_delta_tree(): void
    {
        $this->fakePackStorage();
        $version = $this->publishFixturePack();

        $disk = Storage::disk((string) config('coloringbook.storage.packs_disk'));

        $disk->assertExists('forest-friends/v1/pack.zip');
        $disk->assertExists('forest-friends/v1/manifest.json');

        foreach (array_keys($version->files()) as $path) {
            $disk->assertExists('forest-friends/v1/files/'.$path);
        }

        $this->assertSame(
            $version->archive_sha256,
            hash('sha256', (string) $disk->get('forest-friends/v1/pack.zip')),
        );
        $this->assertSame(
            $version->archive_bytes,
            (int) $disk->size('forest-friends/v1/pack.zip'),
        );
    }

    public function test_it_synthesises_a_book_json_for_a_self_describing_install_tree(): void
    {
        $this->fakePackStorage();
        $version = $this->publishFixturePack();

        $files = $version->files();
        $path = 'books/coyote-2026/book.json';

        $this->assertArrayHasKey($path, $files);

        $disk = Storage::disk((string) config('coloringbook.storage.packs_disk'));
        $contents = (string) $disk->get('forest-friends/v1/files/'.$path);

        $this->assertSame($files[$path]['sha256'], hash('sha256', $contents));
        $this->assertSame($files[$path]['bytes'], strlen($contents));

        /** @var array<string, mixed> $book */
        $book = json_decode($contents, true);

        // Same shape as a manifest books[] entry (§7.2).
        $this->assertSame('coyote-2026', $book['book_uid']);
        $this->assertSame('Coyote', $book['title']);
        $this->assertCount(2, $book['pages']);
    }

    public function test_republishing_creates_the_next_version_and_never_rewrites_the_old_one(): void
    {
        $this->fakePackStorage();

        $first = $this->publishFixturePack();
        $second = $this->publishFixturePack();

        $this->assertSame(1, $first->version);
        $this->assertSame(2, $second->version);
        $this->assertSame(1, Pack::query()->count());

        $reloaded = PackVersion::query()->where('version', 1)->sole();
        $this->assertSame($first->archive_sha256, $reloaded->archive_sha256);
        $this->assertSame(1, $reloaded->manifest['pack_version']);
        $this->assertSame(2, $second->manifest['pack_version']);

        // Books are rebuilt to match the newest release, not duplicated.
        $this->assertSame(2, Book::query()->count());
        $this->assertSame(3, Page::query()->count());
    }

    public function test_it_warns_when_the_manifest_disagrees_about_the_version(): void
    {
        $this->fakePackStorage();

        // The fixture manifest declares pack_version 3; the server assigns v1.
        $this->artisan('pack:publish', ['dir' => $this->fixturePackPath()])
            ->expectsOutputToContain('assigned v1')
            ->assertSuccessful();
    }

    public function test_the_pack_option_publishes_under_a_different_slug(): void
    {
        $this->fakePackStorage();

        $this->artisan('pack:publish', [
            'dir' => $this->fixturePackPath(),
            '--pack' => 'woodland-tales',
        ])->assertSuccessful();

        $pack = Pack::query()->sole();

        $this->assertSame('woodland-tales', $pack->slug);
        $this->assertSame('woodland-tales', $pack->versions()->sole()->manifest['pack_slug']);

        Storage::disk((string) config('coloringbook.storage.packs_disk'))
            ->assertExists('woodland-tales/v1/pack.zip');
    }

    public function test_free_and_paid_contradict_each_other(): void
    {
        $this->fakePackStorage();

        $this->artisan('pack:publish', [
            'dir' => $this->fixturePackPath(),
            '--free' => true,
            '--paid' => true,
        ])->assertExitCode(2);

        $this->assertSame(0, Pack::query()->count());
    }

    public function test_it_refuses_a_directory_that_is_not_a_pack(): void
    {
        $this->fakePackStorage();

        $this->artisan('pack:publish', ['dir' => $this->scratch()])
            ->assertFailed();

        $this->assertSame(0, Pack::query()->count());
    }

    public function test_it_refuses_a_pack_whose_manifest_and_files_came_from_different_runs(): void
    {
        $this->fakePackStorage();

        $directory = $this->copyFixturePack($this->scratch());
        $target = $directory.'/books/coyote-2026/page_01_idmap.png';
        file_put_contents($target, (string) file_get_contents($target).'tampered');

        try {
            app(PublishPackDirectory::class)->handle($directory);
            $this->fail('a stale pack directory was published');
        } catch (PackPublishException $e) {
            $this->assertNotEmpty($e->errors);
            $this->assertStringContainsString('came from different runs', implode(' ', $e->errors));
        }

        $this->assertSame(0, Pack::query()->count());
    }

    public function test_it_refuses_a_pack_that_is_missing_a_file_it_lists(): void
    {
        $this->fakePackStorage();

        $directory = $this->copyFixturePack($this->scratch());
        unlink($directory.'/books/badger-2026/page_01_regions.json');

        try {
            app(PublishPackDirectory::class)->handle($directory);
            $this->fail('an incomplete pack directory was published');
        } catch (PackPublishException $e) {
            $this->assertStringContainsString(
                'books/badger-2026/page_01_regions.json',
                implode(' ', $e->errors),
            );
        }
    }

    public function test_it_refuses_a_book_uid_that_belongs_to_another_pack(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack();

        // Reusing a uid would silently merge two different books' saves (§6.1).
        try {
            $this->publishFixturePack('other-pack');
            $this->fail('a duplicated book_uid was published');
        } catch (PackPublishException $e) {
            $this->assertStringContainsString('already belongs to a different pack', implode(' ', $e->errors));
        }

        $this->assertSame(1, Pack::query()->count());
    }

    public function test_it_reports_every_problem_at_once(): void
    {
        $this->fakePackStorage();

        $directory = $this->copyFixturePack($this->scratch());

        /** @var array<string, mixed> $manifest */
        $manifest = json_decode((string) file_get_contents($directory.'/manifest.json'), true);
        unset($manifest['title']);
        $manifest['manifest_version'] = 99;
        $manifest['books'][0]['book_uid'] = '';
        file_put_contents($directory.'/manifest.json', (string) json_encode($manifest));

        try {
            app(PublishPackDirectory::class)->handle($directory);
            $this->fail('an invalid manifest was published');
        } catch (PackPublishException $e) {
            $this->assertGreaterThanOrEqual(3, count($e->errors));
            $joined = implode(' ', $e->errors);
            $this->assertStringContainsString('manifest_version 99 is not supported', $joined);
            $this->assertStringContainsString('title is missing', $joined);
            $this->assertStringContainsString('book_uid is missing', $joined);
        }
    }

    public function test_a_published_pack_is_immediately_visible_and_downloadable(): void
    {
        $this->fakePackStorage();

        $this->artisan('pack:publish', ['dir' => $this->fixturePackPath(), '--free' => true])
            ->assertSuccessful();

        $version = PackVersion::query()->sole();

        $this->getJson('/api/v1/packs')
            ->assertOk()
            ->assertJsonPath('packs.0.slug', 'forest-friends')
            ->assertJsonPath('packs.0.latest_version', 1);

        $bearer = $this->issueDeviceToken(User::factory()->create());

        $this->withToken($bearer)
            ->getJson('/api/v1/packs/forest-friends/manifest')
            ->assertOk()
            ->assertExactJson($version->manifest);

        $location = (string) $this->withToken($bearer)
            ->get('/api/v1/packs/forest-friends/download')
            ->headers->get('Location');

        $this->flushHeaders();
        $bytes = $this->get($location)->streamedContent();

        $this->assertSame($version->archive_sha256, hash('sha256', $bytes));
    }

    /**
     * A throwaway directory that disappears with the test run.
     */
    private function scratch(): string
    {
        $path = storage_path('framework/testing/packs/'.uniqid('src', true));

        File::ensureDirectoryExists($path);

        $this->beforeApplicationDestroyed(function () use ($path): void {
            File::deleteDirectory($path);
        });

        return $path;
    }
}
