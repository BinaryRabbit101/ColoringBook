<?php

namespace App\Actions\Sync;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\PaintLayer;
use App\Models\RetainedPaintLayer;
use App\Models\User;
use App\Services\PaintStorage;
use App\Services\ShelfClock;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;

/**
 * Wipe one shelf — BL-18, DLC_SERVER.md §6.3 "Erasure".
 *
 * This is the server half of "Erase all progress", and it is reached two ways:
 * the parent dashboard (`settings/progress`), where the grown-up already is,
 * and `DELETE /api/v1/sync/progress`, which is the game pushing the same
 * decision up from the tablet the button was pressed on.
 *
 * Both do exactly this, in this order:
 *
 * 1. **Advance the shelf clock** to the erase instant. This happens first and
 *    inside the transaction because it is the only part that must survive: the
 *    rows below are an absence afterwards, and an absence loses the §6.3 merge
 *    to any device still holding the old state. The clock is what turns the
 *    absence into a state that wins.
 * 2. **Delete the rows** — retained versions, paint layers, progress — for
 *    every book on this shelf and nothing beyond it. Another child's shelf on
 *    the same account is untouched.
 * 3. **Sweep the blobs**, after the commit. A disk cannot be rolled back, so a
 *    row without its file is the failure to prefer over a file without its
 *    row; the same order `DeleteAccount` uses.
 *
 * Nothing is retained. §6.3's 30-day safety net exists for a *lost race* — a
 * picture nobody chose to lose — and this is the opposite: a grown-up asking,
 * behind a confirmation, for it all to be gone. Keeping copies of a child's
 * drawings after that would be the surprising answer, not the safe one.
 */
class EraseShelf
{
    public function __construct(
        private readonly ShelfClock $clock,
        private readonly PaintStorage $paint,
    ) {}

    /**
     * @return ShelfErasureOutcome what was removed, and the clock devices must converge on
     */
    public function handle(User $user, ?ChildProfile $profile, ?CarbonImmutable $at = null): ShelfErasureOutcome
    {
        $at ??= CarbonImmutable::now();

        /** @var list<string> $directories */
        $directories = [];
        $books = 0;
        $pictures = 0;

        $erasedAt = DB::transaction(function () use ($user, $profile, $at, &$directories, &$books, &$pictures): CarbonImmutable {
            $erasedAt = $this->clock->record($user, $profile, $at);

            $shelf = BookProgress::query()
                ->where('user_id', $user->id)
                ->forProfile($profile)
                ->with(['user', 'childProfile'])
                ->lockForUpdate()
                ->get();

            if ($shelf->isEmpty()) {
                return $erasedAt;
            }

            $books = $shelf->count();
            $ids = $shelf->pluck('id')->all();

            foreach ($shelf as $progress) {
                // Resolved before the rows go, because the path is built from
                // the row's own relations.
                $directories[] = $this->paint->directoryFor($progress);
            }

            $layers = PaintLayer::query()->whereIn('book_progress_id', $ids);
            $pictures = (clone $layers)->count();

            // Explicitly, in dependency order, so the sweep is still correct
            // on a connection with foreign keys switched off — the rule
            // `DeleteAccount` and `DeleteChildProfile` already follow.
            RetainedPaintLayer::query()
                ->whereIn('paint_layer_id', (clone $layers)->select('id'))
                ->delete();

            $layers->delete();

            BookProgress::query()->whereIn('id', $ids)->delete();

            return $erasedAt;
        });

        foreach (array_unique($directories) as $directory) {
            $this->paint->forgetDirectory($directory);
        }

        return new ShelfErasureOutcome($erasedAt, $books, $pictures);
    }
}
