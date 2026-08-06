<?php

namespace App\Services;

/**
 * One book as a device pushed it: the state it holds, the `book_uid` it holds
 * it for, and the `base_revision` it believes the server is on.
 *
 * The base revision is the whole optimistic-concurrency story (§6.3): if the
 * server has moved on, the push is refused and the device is handed the
 * server's state to merge and retry.
 */
final class ProgressPush
{
    public function __construct(
        public readonly string $bookUid,
        public readonly int $baseRevision,
        public readonly ProgressState $state,
    ) {}
}
