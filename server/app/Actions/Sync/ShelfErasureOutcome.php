<?php

namespace App\Actions\Sync;

use Carbon\CarbonImmutable;

/**
 * What a shelf wipe did (BL-18).
 *
 * `erasedAt` is the only part that matters to a device: it is the clock every
 * other device measures its own state against, and the thing the API echoes
 * back. The two counts are for the grown-up's confirmation line ("3 books and
 * 11 pictures erased") and for tests.
 */
final class ShelfErasureOutcome
{
    public function __construct(
        public readonly CarbonImmutable $erasedAt,
        public readonly int $books,
        public readonly int $pictures,
    ) {}
}
