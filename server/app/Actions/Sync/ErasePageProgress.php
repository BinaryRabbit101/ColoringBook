<?php

namespace App\Actions\Sync;

use App\Exceptions\ApiException;
use App\Http\Resources\PaintLayerResource;
use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\PaintLayer;
use App\Models\RetainedPaintLayer;
use App\Models\User;
use App\Services\PaintStorage;
use Carbon\CarbonImmutable;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Symfony\Component\HttpFoundation\Response;

/**
 * "Start over" on one page — BL-7 locally, BL-18 across devices.
 *
 * The page's paint is deleted and its status put back to `untouched`. Both
 * halves have the same problem: §6.3's merge only climbs, and LWW keeps the
 * newest picture, so a *local* reset lost both comparisons on the next pull —
 * the picture came back and so did the `complete` badge.
 *
 * So the reset is pushed as an instant, and that one instant does both jobs:
 *
 * - **The picture.** `client_erased_at` is compared to `client_painted_at`
 *   exactly as another upload would be. Newer (or an exact tie) wins and the
 *   layer row and its blob go; older loses with `PAINT_STALE`, because a
 *   picture painted on another device *after* the reset is the newer statement
 *   about that page and pulling it is the right answer.
 * - **The status.** The instant is written to `book_progress.page_erased_at`
 *   for that page, which censors every side of the merge whose
 *   `client_updated_at` is at or before it. That is what stops a device still
 *   holding `complete` from putting the badge back on a blank page.
 *
 * The progress row's `revision` and `updated_at` both move. A paint *upload*
 * deliberately leaves them alone (a picture is no news to the other devices),
 * but an erase changes progress, so it has to wake the `since` cursor and make
 * every stale `base_revision` conflict.
 *
 * **Nothing is retained.** §6.3's 30-day net catches a *lost race*; this is a
 * deliberate reset, confirmed on the device, and it already deletes the local
 * file with no undo. Keeping the server's copy would make the two ends
 * disagree about what "start over" means.
 */
class ErasePageProgress
{
    public function __construct(private readonly PaintStorage $storage) {}

    public function handle(
        User $user,
        ?ChildProfile $profile,
        string $bookUid,
        int $pageIndex,
        CarbonImmutable $erasedAt,
    ): PageErasureOutcome {
        $progress = $this->shelf($user, $profile, $bookUid);

        [$outcome, $paths] = DB::transaction(function () use ($progress, $pageIndex, $erasedAt): array {
            /** @var BookProgress $row */
            $row = BookProgress::query()->whereKey($progress->id)->lockForUpdate()->firstOrFail();

            $layer = PaintLayer::query()
                ->where('book_progress_id', $row->id)
                ->where('page_index', $pageIndex)
                ->lockForUpdate()
                ->first();

            if ($layer !== null && $layer->client_painted_at->greaterThan($erasedAt)) {
                throw new ApiException(
                    'PAINT_STALE',
                    __('The server already has a newer picture for that page.'),
                    Response::HTTP_CONFLICT,
                    ['server' => PaintLayerResource::describe($layer)],
                );
            }

            /** @var list<string> $paths */
            $paths = [];

            if ($layer !== null) {
                $paths[] = $layer->storage_path;

                $retained = RetainedPaintLayer::query()->where('paint_layer_id', $layer->id)->get();

                // The older versions go too. Keeping them would leave the
                // dashboard offering to restore a picture onto a page that has
                // deliberately been started over.
                foreach ($retained as $version) {
                    $paths[] = $version->storage_path;
                }

                RetainedPaintLayer::query()->where('paint_layer_id', $layer->id)->delete();
                $layer->delete();
            }

            // Monotonic, so a replayed erase is free — and so a device
            // re-sending its whole shelf cannot walk the clock backwards.
            $moved = $row->erasePage($pageIndex, $erasedAt);

            if ($moved) {
                $row->revision++;
                $row->save();
            }

            return [
                new PageErasureOutcome($row, $pageIndex, $erasedAt, $layer !== null, $moved),
                $paths,
            ];
        });

        // After the commit: a disk cannot be rolled back, and a row pointing
        // at a file that is gone is the failure to prefer over a file nothing
        // points at.
        foreach ($paths as $path) {
            if ($path !== '') {
                $this->storage->delete($path);
            }
        }

        return $outcome;
    }

    /**
     * The `book_progress` row the erase hangs off, created if the shelf has
     * never synced this book.
     *
     * Created for the same reason `StorePaintLayer` creates one: the erase
     * clock has to live *somewhere* durable, or a device that has the picture
     * and has not yet pushed it would upload it back after the reset. An empty
     * row with one erased page is a small price for that not happening.
     */
    private function shelf(User $user, ?ChildProfile $profile, string $bookUid): BookProgress
    {
        $existing = $this->findShelf($user, $profile, $bookUid);

        if ($existing !== null) {
            return $existing;
        }

        $progress = new BookProgress;
        $progress->user_id = $user->id;
        $progress->child_profile_id = $profile?->id;
        $progress->book_uid = $bookUid;
        $progress->revision = 1;
        $progress->current_page_index = 0;
        $progress->page_statuses = [];
        $progress->furthest_page_index = 0;
        $progress->client_updated_at = CarbonImmutable::now();

        try {
            $progress->save();
        } catch (QueryException $e) {
            $progress = $this->findShelf($user, $profile, $bookUid);

            if ($progress === null) {
                throw $e;
            }
        }

        return $progress;
    }

    private function findShelf(User $user, ?ChildProfile $profile, string $bookUid): ?BookProgress
    {
        return BookProgress::query()
            ->where('user_id', $user->id)
            ->forProfile($profile)
            ->where('book_uid', $bookUid)
            ->first();
    }
}
