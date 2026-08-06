<?php

namespace App\Services;

/**
 * What §10.1 found. Two lists, because the admin flow reports
 * `{version, warnings[], errors[]}` and the two mean different things:
 *
 * - an **error** stops the draft being created — the pack cannot be shipped;
 * - a **warning** is something the reviewer should look at before publishing
 *   but which does not make the artifacts unusable.
 */
final readonly class PackValidationResult
{
    /**
     * @param  list<string>  $errors
     * @param  list<string>  $warnings
     */
    public function __construct(
        public array $errors = [],
        public array $warnings = [],
    ) {}

    /**
     * @param  list<string>  $errors
     */
    public static function failed(array $errors): self
    {
        return new self($errors);
    }

    public function merge(self $other): self
    {
        return new self(
            [...$this->errors, ...$other->errors],
            [...$this->warnings, ...$other->warnings],
        );
    }

    public function passed(): bool
    {
        return $this->errors === [];
    }
}
