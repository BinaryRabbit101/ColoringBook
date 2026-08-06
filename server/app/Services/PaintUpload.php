<?php

namespace App\Services;

use Carbon\CarbonImmutable;

/**
 * One page's pixels on their way in, as a value.
 *
 * `sha256` is the *negotiated* hash — what `POST /sync/paint/...` was told and
 * what the `Content-Digest` header must agree with — not something recomputed
 * from `$contents` on the way past. The controller proves all three match
 * before this object exists, which is why nothing downstream re-hashes.
 */
final class PaintUpload
{
    public function __construct(
        public readonly string $sha256,
        public readonly int $bytes,
        public readonly string $contents,
        public readonly CarbonImmutable $clientPaintedAt,
    ) {}
}
