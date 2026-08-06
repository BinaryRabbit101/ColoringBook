<?php

namespace Tests\Concerns;

use App\Actions\Packs\PublishPackDirectory;
use App\Models\PackVersion;
use Illuminate\Support\Facades\Storage;

/**
 * Seeding the catalog the way a release actually happens.
 *
 * Nothing here hand-builds a `pack_versions` row: the tests publish the
 * `tests/Fixtures/packs/forest-friends` directory through the same action
 * `pack:publish` uses, so the bytes a test downloads are the bytes a player
 * would receive — zip framing, synthesised `book.json` and all.
 *
 * The fixture is deliberately tiny (8x8 PNGs, ~7 KB total) but structurally
 * real: two books, three pages, a pack cover that doubles as a book cover
 * (which exercises one blob wearing two `assets.kind` hats), lossless PNGs
 * with `#000000` lines and flat per-region colours in the ID maps.
 */
trait PublishesPacks
{
    /**
     * Point the private disks at throwaway directories. Call before
     * publishing: content-addressed writes are the first thing that happens.
     */
    protected function fakePackStorage(): void
    {
        Storage::fake((string) config('coloringbook.storage.packs_disk'));
        Storage::fake((string) config('coloringbook.storage.assets_disk'));
    }

    protected function fixturePackPath(string $name = 'forest-friends'): string
    {
        return dirname(__DIR__).DIRECTORY_SEPARATOR.'Fixtures'
            .DIRECTORY_SEPARATOR.'packs'.DIRECTORY_SEPARATOR.$name;
    }

    /**
     * Publish the fixture and hand back the release it created.
     */
    protected function publishFixturePack(?string $slug = null, ?bool $free = null): PackVersion
    {
        return app(PublishPackDirectory::class)
            ->handle($this->fixturePackPath(), $slug, $free)
            ->version;
    }

    /**
     * A copy of the fixture in a scratch directory, for tests that need to
     * damage it (a stale digest, a missing file) without touching the real
     * one.
     */
    protected function copyFixturePack(string $into): string
    {
        $source = $this->fixturePackPath();

        foreach ($this->fixtureFiles($source) as $relative) {
            $target = $into.DIRECTORY_SEPARATOR.$relative;

            if (! is_dir(dirname($target))) {
                mkdir(dirname($target), 0777, true);
            }

            copy($source.DIRECTORY_SEPARATOR.$relative, $target);
        }

        return $into;
    }

    /**
     * @return array<int, string>
     */
    private function fixtureFiles(string $source): array
    {
        $paths = [];

        /** @var iterable<\SplFileInfo> $iterator */
        $iterator = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($source, \FilesystemIterator::SKIP_DOTS),
        );

        foreach ($iterator as $file) {
            if ($file->isFile()) {
                $paths[] = ltrim(str_replace($source, '', $file->getPathname()), '/\\');
            }
        }

        return $paths;
    }
}
