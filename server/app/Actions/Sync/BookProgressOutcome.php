<?php

namespace App\Actions\Sync;

use App\Models\BookProgress;

/**
 * What became of one book in a batched `PUT /sync/progress`.
 *
 * `conflict` means the push was refused because the row had moved on since
 * the device's `base_revision`; `progress` is then the server's current row,
 * which is exactly what the device needs to merge locally and retry once.
 */
final class BookProgressOutcome
{
    public function __construct(
        public readonly BookProgress $progress,
        public readonly bool $conflict,
    ) {}
}
