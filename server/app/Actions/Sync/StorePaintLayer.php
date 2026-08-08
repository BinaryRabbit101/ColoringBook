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
use App\Services\PaintUpload;
use App\Services\PaintUploads;
use App\Services\ShelfClock;
use Carbon\CarbonImmutable;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Symfony\Component\HttpFoundation\Response;

/**
 * Store one page's pixels under last-write-wins (DLC_SERVER.md §6.3).
 *
 * Four outcomes:
 *
 * - **Same bytes.** The incoming sha256 equals the stored one. Nothing is
 *   written, no revision is burned, nothing is retained — re-syncing an
 *   unchanged page is free, which is the whole point of the sha-first
 *   negotiation. `client_painted_at` is deliberately *not* advanced either:
 *   the row describes a picture, and that picture has not changed.
 * - **No row yet.** Created at revision 1, along with the `book_progress` row
 *   if the shelf has never synced this book (paint can legitimately arrive
 *   before progress does — the client uploads at the same save points, and the
 *   two requests race).
 * - **Incoming is newer (or exactly ties).** It wins. The displaced version is
 *   moved to `page_NN.<revision>.png` and recorded in `retained_paint_layers`,
 *   the row is rewritten and `revision` bumped.
 * - **Incoming is older.** It loses, and says so: `PAINT_STALE` (409) carrying
 *   the server's current metadata. Nothing is written. Rejecting rather than
 *   silently discarding is what lets the client know its local picture is the
 *   stale one and pull instead — a silent 201 would leave two devices each
 *   believing they own the page.
 *
 * **Ties go to the arriving write.** §6.3 says the server clock is the
 * tie-break, and by the server's clock the write happening now is the later
 * one. It also makes the common accident harmless: a device whose clock has
 * one-second resolution re-uploading a page it just changed.
 *
 * A winning write does **not** touch `book_progress.updated_at`. That column
 * is WP2's `since` cursor, and waking every other device on the account to
 * re-pull unchanged progress because a picture was uploaded would be a lot of
 * traffic for no news.
 */
class StorePaintLayer
{
    public function __construct(
        private readonly PaintStorage $storage,
        private readonly PaintUploads $uploads,
        private readonly ShelfClock $clock,
    ) {}

    public function handle(
        User $user,
        ?ChildProfile $profile,
        string $bookUid,
        int $pageIndex,
        PaintUpload $upload,
    ): PaintWriteOutcome {
        // BL-18, and before `shelf()` on purpose: that method *creates* the
        // `book_progress` row, so a stale upload against a wiped shelf would
        // put the book back on it before anything had a chance to say no.
        $this->uploads->assertShelfNotErased(
            $this->clock->erasedAt($user, $profile),
            $upload->clientPaintedAt,
        );

        $progress = $this->shelf($user, $profile, $bookUid);

        // A page that has been started over more recently than this picture
        // was painted refuses it outright. Checked before the row is locked
        // because it is a property of the page, not of the race.
        $this->uploads->assertNotErased($progress->erasedPageAt($pageIndex), $upload->clientPaintedAt);

        return DB::transaction(function () use ($progress, $pageIndex, $upload): PaintWriteOutcome {
            $layer = PaintLayer::query()
                ->where('book_progress_id', $progress->id)
                ->where('page_index', $pageIndex)
                ->lockForUpdate()
                ->first();

            if ($layer === null) {
                return new PaintWriteOutcome($this->create($progress, $pageIndex, $upload), written: true);
            }

            if ($layer->sha256 === $upload->sha256) {
                return new PaintWriteOutcome($layer, written: false);
            }

            if ($upload->clientPaintedAt->lessThan($layer->client_painted_at)) {
                throw new ApiException(
                    'PAINT_STALE',
                    __('The server already has a newer picture for that page.'),
                    Response::HTTP_CONFLICT,
                    ['server' => PaintLayerResource::describe($layer)],
                );
            }

            return new PaintWriteOutcome($this->replace($layer, $upload), written: true);
        });
    }

    /**
     * First picture on this page.
     */
    private function create(BookProgress $progress, int $pageIndex, PaintUpload $upload): PaintLayer
    {
        $path = $this->storage->currentPath($progress, $pageIndex);

        $layer = new PaintLayer;
        $layer->book_progress_id = $progress->id;
        $layer->page_index = $pageIndex;
        $layer->sha256 = $upload->sha256;
        $layer->bytes = $upload->bytes;
        $layer->storage_path = $path;
        $layer->revision = 1;
        $layer->client_painted_at = $upload->clientPaintedAt;
        $layer->save();

        $this->storage->put($path, $upload->contents);

        return $layer;
    }

    /**
     * The winning write: retain what was there, then overwrite.
     *
     * The order matters. The old blob is renamed out of the way *before* the
     * new one lands, so there is no window in which the file at `page_NN.png`
     * is the new picture while the row still claims the old digest.
     */
    private function replace(PaintLayer $layer, PaintUpload $upload): PaintLayer
    {
        $this->retain($layer);

        $layer->sha256 = $upload->sha256;
        $layer->bytes = $upload->bytes;
        $layer->revision = $layer->revision + 1;
        $layer->client_painted_at = $upload->clientPaintedAt;
        $layer->save();

        $this->storage->put($layer->storage_path, $upload->contents);

        return $layer;
    }

    /**
     * Move the current blob aside and remember it for 30 days.
     */
    private function retain(PaintLayer $layer): RetainedPaintLayer
    {
        $retainedPath = $this->storage->retainedPath($layer->storage_path, $layer->revision);

        $this->storage->move($layer->storage_path, $retainedPath);

        $retained = new RetainedPaintLayer;
        $retained->paint_layer_id = $layer->id;
        $retained->sha256 = $layer->sha256;
        $retained->bytes = $layer->bytes;
        $retained->storage_path = $retainedPath;
        $retained->revision = $layer->revision;
        $retained->client_painted_at = $layer->client_painted_at;
        $retained->retained_at = CarbonImmutable::now();
        $retained->save();

        return $retained;
    }

    /**
     * The `book_progress` row the paint hangs off, created if the shelf has
     * never synced this book.
     *
     * Created empty — revision 1, no page statuses — rather than inferring
     * anything from the upload: a page having paint on it does not tell us it
     * is `in_progress`, let alone how many pages the book has. The next
     * `PUT /sync/progress` merges the real statuses in, and `ProgressMerge`
     * pads unequal page counts with `untouched`, so an empty list is the
     * identity rather than a claim.
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
            // Two tablets uploading two pages of a never-synced book at the
            // same instant. The unique index is the arbiter; whoever lost the
            // race just reads the row the winner made.
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
