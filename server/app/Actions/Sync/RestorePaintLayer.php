<?php

namespace App\Actions\Sync;

use App\Models\PaintLayer;
use App\Models\RetainedPaintLayer;
use App\Services\PaintStorage;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;

/**
 * "Restore the older picture" — the safety net behind last-write-wins (§6.3).
 *
 * A straight swap, not a rollback: the retained version becomes current and
 * the version it displaces takes its place in retention with a fresh 30-day
 * lease. Pressing the button twice therefore returns the page to where it
 * started, which is the behaviour a parent who mis-clicked expects, and it
 * means the button can never destroy the picture it is replacing.
 *
 * ### Why the restored picture gets a new `client_painted_at`
 *
 * A restore would be pointless if it lost the very next sync. The device that
 * won the race still holds the newer picture, and its next upload would beat
 * anything stamped with the older timestamp. So the restored layer is stamped
 * with the server's clock — a deliberate act by the account's owner is the
 * newest statement of intent about that page. (Nudged past the demoted
 * timestamp when a device's clock is running ahead of the server's, since
 * `client_painted_at` may legitimately sit up to the skew window in the
 * future.)
 *
 * The original painting time is not lost: it travels with the version into
 * `retained_paint_layers`, which is what the dashboard shows.
 */
class RestorePaintLayer
{
    public function __construct(private readonly PaintStorage $storage) {}

    public function handle(RetainedPaintLayer $retained): PaintLayer
    {
        return DB::transaction(function () use ($retained): PaintLayer {
            /** @var PaintLayer $layer */
            $layer = PaintLayer::query()
                ->whereKey($retained->paint_layer_id)
                ->lockForUpdate()
                ->firstOrFail();

            $currentPath = $layer->storage_path;

            // Demote what is live now, with its own revision as the suffix.
            $demotedPath = $this->storage->retainedPath($currentPath, $layer->revision);
            $this->storage->move($currentPath, $demotedPath);

            $demoted = new RetainedPaintLayer;
            $demoted->paint_layer_id = $layer->id;
            $demoted->sha256 = $layer->sha256;
            $demoted->bytes = $layer->bytes;
            $demoted->storage_path = $demotedPath;
            $demoted->revision = $layer->revision;
            $demoted->client_painted_at = $layer->client_painted_at;
            $demoted->retained_at = CarbonImmutable::now();
            $demoted->save();

            // Promote the older picture back into place.
            $this->storage->move($retained->storage_path, $currentPath);

            $layer->sha256 = $retained->sha256;
            $layer->bytes = $retained->bytes;
            $layer->storage_path = $currentPath;
            $layer->revision = $layer->revision + 1;
            $layer->client_painted_at = $this->restoredAt($demoted->client_painted_at);
            $layer->save();

            $retained->delete();

            return $layer;
        });
    }

    /**
     * Now, unless a device's clock has put the demoted version in the future —
     * in which case just past it, so the restore still wins LWW.
     */
    private function restoredAt(CarbonImmutable $demotedAt): CarbonImmutable
    {
        $now = CarbonImmutable::now();

        return $now->greaterThan($demotedAt) ? $now : $demotedAt->addSecond();
    }
}
