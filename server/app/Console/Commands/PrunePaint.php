<?php

namespace App\Console\Commands;

use App\Actions\Sync\PrunePaintLayers;
use Illuminate\Console\Command;

/**
 * `php artisan paint:prune` — expire the retained losing paint versions
 * (DLC_SERVER.md §6.3).
 *
 *     php artisan paint:prune
 *     php artisan paint:prune --days=7 --pretend
 *
 * Scheduled daily in `routes/console.php`; runnable by hand when a disk is
 * filling up or a retention window has just been shortened. It only ever
 * touches `retained_paint_layers` — a page's *current* picture is never
 * pruned, however old it is.
 */
class PrunePaint extends Command
{
    /** @var string */
    protected $signature = 'paint:prune
        {--days= : Retention window in days, overriding coloringbook.paint.retention_days}
        {--pretend : Report what would go, delete nothing}';

    /** @var string */
    protected $description = 'Delete retained older paint versions past their retention window';

    public function handle(PrunePaintLayers $prune): int
    {
        $days = $this->option('days');
        $days = is_numeric($days) ? (int) $days : null;
        $window = $days ?? (int) config('coloringbook.paint.retention_days');

        if ($window < 1) {
            $this->components->error('A retention window of less than a day would delete a picture a parent is still looking at.');

            return self::INVALID;
        }

        if ($this->option('pretend') === true) {
            $count = $prune->expiring($days)->count();

            $this->components->info("{$count} retained picture(s) are past {$window} days.");

            return self::SUCCESS;
        }

        $pruned = $prune->handle($days);

        $this->components->info("Pruned {$pruned} retained picture(s) older than {$window} days.");

        return self::SUCCESS;
    }
}
