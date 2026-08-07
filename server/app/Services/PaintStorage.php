<?php

namespace App\Services;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\User;
use Illuminate\Contracts\Filesystem\Filesystem;
use Illuminate\Support\Facades\Storage;

/**
 * Where a page's pixels live, and the only code that names those files.
 *
 * DLC_SERVER.md §5 gives the layout as
 * `paint/<user_ulid>/<book_uid>/page_NN.png`, which is the disk root plus
 * `<user_ulid>/<book_uid>/page_NN.png`. That is exactly what an account-level
 * shelf gets.
 *
 * A **child's** shelf takes one extra segment,
 * `<user_ulid>/<profile_ulid>/<book_uid>/page_NN.png`, because §5's layout
 * predates profiles and two children painting the same book on one account
 * would otherwise write to the same file. There is no ambiguity between the
 * two shapes: a `book_uid` is authored lower-case slug-shaped (§6.1) and a
 * ULID is upper-case Crockford base32, so no directory can be read as either.
 *
 * `NN` is **1-based** while `page_index` is 0-based, matching what the game
 * already writes to `user://paint/<slug>/page_NN.png` (`game_state.gd`): the
 * server's tree is the client's tree, which makes a support question ("which
 * file is this?") answerable without a lookup table.
 */
class PaintStorage
{
    public function disk(): Filesystem
    {
        return Storage::disk((string) config('coloringbook.storage.paint_disk'));
    }

    /**
     * The directory holding one shelf's pictures for one book.
     */
    public function directoryFor(BookProgress $progress): string
    {
        $segments = [$progress->user->ulid];

        if ($progress->child_profile_id !== null) {
            $segments[] = $progress->childProfile->ulid;
        }

        $segments[] = $progress->book_uid;

        return implode('/', $segments);
    }

    /**
     * The live picture for a page.
     */
    public function currentPath(BookProgress $progress, int $pageIndex): string
    {
        return $this->directoryFor($progress).'/'.$this->fileName($pageIndex);
    }

    /**
     * Where a version goes when it loses (or is demoted by a restore).
     *
     * Derived from the live path rather than rebuilt, so a row written under
     * an older layout still retains beside its own file.
     */
    public function retainedPath(string $currentPath, int $revision): string
    {
        return preg_replace('/\.png$/i', '.'.$revision.'.png', $currentPath) ?? $currentPath;
    }

    /**
     * `page_01.png` for page index 0 — 1-based on disk, like the client's.
     */
    public function fileName(int $pageIndex): string
    {
        return sprintf('page_%02d.png', $pageIndex + 1);
    }

    public function put(string $path, string $contents): void
    {
        $this->disk()->put($path, $contents);
    }

    /**
     * Rename, tolerating a missing source.
     *
     * A row whose blob has gone (a half-restored backup, a manual tidy-up) must
     * not be able to fail an upload: the picture the child just painted is
     * worth more than the one that is already missing.
     */
    public function move(string $from, string $to): bool
    {
        $disk = $this->disk();

        if (! $disk->exists($from)) {
            return false;
        }

        return $disk->move($from, $to);
    }

    public function delete(string $path): void
    {
        $this->disk()->delete($path);
    }

    /**
     * Sweep every picture on the account. Called when the account is deleted:
     * "must actually delete (progress rows, paint blobs, profiles)" (§4.1).
     */
    public function forgetUser(User $user): void
    {
        $this->disk()->deleteDirectory($user->ulid);
    }

    /**
     * Sweep one child's pictures, leaving the rest of the household alone.
     */
    public function forgetProfile(ChildProfile $profile): void
    {
        $this->disk()->deleteDirectory($profile->user->ulid.'/'.$profile->ulid);
    }

    /**
     * Sweep one book directory, named by `directoryFor()` before its row was
     * deleted (BL-18's shelf wipe).
     *
     * Deliberately not "sweep the shelf": the account-level shelf's books sit
     * directly under `paint/<user_ulid>/`, *beside* the child directories, so
     * there is no one directory that means "the account's pictures and not the
     * children's". Naming each book is the only precise answer.
     */
    public function forgetDirectory(string $directory): void
    {
        if ($directory === '') {
            return;
        }

        $this->disk()->deleteDirectory($directory);
    }
}
