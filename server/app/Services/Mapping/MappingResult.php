<?php

namespace App\Services\Mapping;

/**
 * What one mapping run came back with.
 *
 * `output` is kept whole and stored on the page: the pipeline prints the
 * tunables it actually used in its run summary, which is what makes a web-mapped
 * page reproducible by hand on the dev box (mapping-pipeline skill). A failure
 * additionally carries a one-line `reason` — the thing the editor puts in front
 * of the operator, because "FAIL: region 3 covers 97% of the paintable pixels"
 * is a sentence and a 200-line log is not.
 */
final readonly class MappingResult
{
    private function __construct(
        public bool $successful,
        public int $exitCode,
        public string $output,
        public ?string $reason = null,
    ) {}

    public static function succeeded(string $output = ''): self
    {
        return new self(true, 0, $output);
    }

    public static function failed(string $reason, string $output = '', int $exitCode = 1): self
    {
        return new self(false, $exitCode, $output === '' ? $reason : $output, $reason);
    }
}
