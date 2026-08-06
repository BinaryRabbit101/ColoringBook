<?php

namespace App\Actions\Sync;

use App\Models\RetainedPaintLayer;
use App\Services\PaintStorage;
use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Collection;

/**
 * Drop retained pictures whose 30-day lease has run out (§6.3).
 *
 * The blob goes first and the row second: a row without its file is a broken
 * "restore" button in the dashboard, while a file without its row is invisible
 * to everything and gets swept by the next account deletion. If the process
 * dies mid-sweep, that is the direction to fail in.
 *
 * Retention is *not* a backup. It exists for one failure mode — a picture
 * overwritten by another device — and 30 days is the design's number, not a
 * promise about anything else.
 */
class PrunePaintLayers
{
    public function __construct(private readonly PaintStorage $storage) {}

    /**
     * @param  int|null  $days  Overrides `coloringbook.paint.retention_days`.
     * @return int How many retained versions were deleted.
     */
    public function handle(?int $days = null): int
    {
        $pruned = 0;

        $this->expiring($days)
            ->orderBy('id')
            ->chunkById(200, function (Collection $expired) use (&$pruned): void {
                /** @var Collection<int, RetainedPaintLayer> $expired */
                foreach ($expired as $retained) {
                    $this->storage->delete($retained->storage_path);
                    $retained->delete();
                    $pruned++;
                }
            });

        return $pruned;
    }

    /**
     * Everything the next sweep would take. Shared with `--pretend`, so the
     * dry run can never disagree with the real thing.
     *
     * @param  int|null  $days  Overrides `coloringbook.paint.retention_days`.
     * @return Builder<RetainedPaintLayer>
     */
    public function expiring(?int $days = null): Builder
    {
        $days ??= (int) config('coloringbook.paint.retention_days');

        return RetainedPaintLayer::query()->expired(CarbonImmutable::now()->subDays($days));
    }
}
