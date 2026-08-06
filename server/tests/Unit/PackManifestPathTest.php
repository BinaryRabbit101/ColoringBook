<?php

namespace Tests\Unit;

use App\Services\PackManifest;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * The single definition of a safe pack-relative path, used both when
 * publishing and when serving `/packs/{slug}/files/{path}`.
 *
 * It is the *second* line of defence — the delta route also requires the path
 * to be a key in the manifest's `files` map — but it is the one that has to
 * hold if a bad manifest ever gets written.
 */
class PackManifestPathTest extends TestCase
{
    /**
     * @return array<string, array{0: string}>
     */
    public static function acceptablePaths(): array
    {
        return [
            'a page' => ['books/coyote-2026/page_01.png'],
            'the cover' => ['cover.png'],
            'a synthesised book file' => ['books/badger-2026/book.json'],
            'a dot inside a name' => ['books/coyote-2026/page_01.idmap.png'],
            'a leading dot file' => ['books/coyote-2026/.keep'],
        ];
    }

    /**
     * @return array<string, array{0: string}>
     */
    public static function rejectedPaths(): array
    {
        return [
            'empty' => [''],
            'traversal' => ['../.env'],
            'traversal in the middle' => ['books/../../.env'],
            'a bare dot segment' => ['books/./page_01.png'],
            'absolute' => ['/etc/passwd'],
            'a windows drive' => ['C:/Windows/win.ini'],
            'a backslash' => ['books\\coyote\\page_01.png'],
            'a doubled slash' => ['books//page_01.png'],
            'a trailing slash' => ['books/coyote-2026/'],
            'a null byte' => ["books/page.png\0.txt"],
            'a newline' => ["books/page\n.png"],
        ];
    }

    #[DataProvider('acceptablePaths')]
    public function test_it_accepts_an_ordinary_pack_relative_path(string $path): void
    {
        $this->assertTrue(PackManifest::isSafeRelativePath($path));
    }

    #[DataProvider('rejectedPaths')]
    public function test_it_rejects_anything_that_could_leave_the_pack(string $path): void
    {
        $this->assertFalse(PackManifest::isSafeRelativePath($path));
    }

    public function test_it_rejects_an_absurdly_long_path(): void
    {
        $this->assertFalse(PackManifest::isSafeRelativePath(str_repeat('a', 1025)));
    }
}
