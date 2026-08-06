<?php

namespace App\Exceptions;

use Exception;
use Throwable;

/**
 * A pack directory the server refuses to publish.
 *
 * Carries *every* reason at once rather than the first one, because the
 * person fixing it is running a CLI against a build tree and wants the whole
 * list, not one round trip per typo (DLC_SERVER.md §10.2).
 *
 * WP5's `POST /admin/packs/{slug}/versions` renders the same list as the
 * `errors[]` array in its response.
 */
class PackPublishException extends Exception
{
    /**
     * @param  array<int, string>  $errors
     */
    public function __construct(
        public readonly array $errors,
        ?Throwable $previous = null,
    ) {
        parent::__construct(
            $errors === [] ? 'The pack could not be published.' : implode(' ', $errors),
            0,
            $previous,
        );
    }
}
