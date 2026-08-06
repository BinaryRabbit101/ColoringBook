<?php

namespace Tests\Concerns;

use App\Models\User;
use Illuminate\Http\UploadedFile;
use ZipArchive;

/**
 * The WP5 fixtures, and the two things an admin test always needs: a token
 * that can publish, and a real zip to upload.
 *
 * `tests/Fixtures/packs/meadow-mates` is a second, deliberately separate pack
 * from WP3's `forest-friends`. It exists because §10.1's checks are stricter
 * than the structural ones WP3 wrote its fixture against: every page here has
 * four regions in the canonical schema-v1 shape the mapping pipeline actually
 * writes (`version`, `id`, `id_color`, `outline`, `holes`, `centroid`,
 * `area_px`), so the pack is a *valid* one end to end rather than merely a
 * well-formed manifest.
 *
 * `tests/Fixtures/pages/<case>` are single pages, each broken in exactly one
 * way, for the unit tests. 16x16 PNGs: two black bars crossing the middle
 * leave four 7x7 quadrants, which is the smallest thing that is still a real
 * region map.
 */
trait AdminsPacks
{
    /**
     * A Sanctum token carrying the `admin` ability and nothing else — what
     * `php artisan admin:token` mints for the dev box's pack-build script.
     */
    protected function adminToken(?User $user = null): string
    {
        $user ??= User::factory()->admin()->create();

        return $user->createToken('pack-build', [(string) config('coloringbook.admin.ability')])
            ->plainTextToken;
    }

    protected function adminPackFixturePath(string $name = 'meadow-mates'): string
    {
        return dirname(__DIR__).DIRECTORY_SEPARATOR.'Fixtures'
            .DIRECTORY_SEPARATOR.'packs'.DIRECTORY_SEPARATOR.$name;
    }

    protected function pageFixturePath(string $case): string
    {
        return dirname(__DIR__).DIRECTORY_SEPARATOR.'Fixtures'
            .DIRECTORY_SEPARATOR.'pages'.DIRECTORY_SEPARATOR.$case;
    }

    /**
     * Zip a pack directory into a real temporary file and wrap it as an
     * upload, so the endpoint sees the bytes a browser would post.
     */
    protected function packUpload(?string $directory = null, string $name = 'pack.zip'): UploadedFile
    {
        $directory = $directory ?? $this->adminPackFixturePath();
        $path = (string) tempnam(sys_get_temp_dir(), 'packzip');

        $zip = new ZipArchive;
        $zip->open($path, ZipArchive::CREATE | ZipArchive::OVERWRITE);

        /** @var iterable<\SplFileInfo> $files */
        $files = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($directory, \FilesystemIterator::SKIP_DOTS),
        );

        foreach ($files as $file) {
            if (! $file->isFile()) {
                continue;
            }

            $relative = str_replace(
                '\\',
                '/',
                ltrim(str_replace($directory, '', $file->getPathname()), '/\\'),
            );

            $zip->addFile($file->getPathname(), $relative);
        }

        $zip->close();

        // `$test: true` keeps Symfony from treating this as a real upload and
        // rejecting it for not having come through PHP's upload machinery.
        return new UploadedFile($path, $name, 'application/zip', null, true);
    }

    /**
     * The fixture's manifest, decoded — for the `manifest + asset ulids` form
     * of the version endpoint.
     *
     * @return array<string, mixed>
     */
    protected function fixtureManifest(?string $directory = null): array
    {
        $directory = $directory ?? $this->adminPackFixturePath();

        /** @var array<string, mixed> $manifest */
        $manifest = json_decode(
            (string) file_get_contents($directory.DIRECTORY_SEPARATOR.'manifest.json'),
            true,
        );

        return $manifest;
    }
}
