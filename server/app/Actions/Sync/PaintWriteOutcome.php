<?php

namespace App\Actions\Sync;

use App\Models\PaintLayer;

/**
 * What `StorePaintLayer` did, so the controller can pick a status without
 * re-reading the row.
 *
 * `written: false` is the idempotent case — the bytes that arrived hash to
 * exactly what is already stored, so nothing moved and nothing was retained.
 */
final class PaintWriteOutcome
{
    public function __construct(
        public readonly PaintLayer $layer,
        public readonly bool $written,
    ) {}
}
