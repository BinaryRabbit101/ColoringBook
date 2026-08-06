<?php

namespace App\Exceptions;

use Exception;
use Symfony\Component\HttpFoundation\Response;
use Throwable;

/**
 * A deliberate, client-facing API failure.
 *
 * Throw this (rather than `abort()`) whenever the game client needs to branch
 * on a *specific* stable code — `ENTITLEMENT_REQUIRED`, `REVISION_CONFLICT`,
 * `DIGEST_MISMATCH` and friends. `ApiExceptionRenderer` turns it into the
 * house error shape:
 *
 *     {"error": {"code": "ENTITLEMENT_REQUIRED", "message": "…"}}
 *
 * The client branches on `code`, never on the prose (DLC_SERVER.md §11).
 */
class ApiException extends Exception
{
    /**
     * @param  string  $errorCode  Stable SNAKE_CASE code the client branches on.
     * @param  array<string, mixed>  $details  Optional structured extra payload.
     */
    public function __construct(
        public readonly string $errorCode,
        string $message,
        public readonly int $status = Response::HTTP_BAD_REQUEST,
        public readonly array $details = [],
        ?Throwable $previous = null,
    ) {
        parent::__construct($message, 0, $previous);
    }

    /**
     * Sign-in was attempted with an email/password pair that doesn't match.
     *
     * Deliberately *not* a 422: the client shows "that didn't work" and never
     * hints at which half was wrong.
     */
    public static function invalidCredentials(): self
    {
        return new self(
            'INVALID_CREDENTIALS',
            __('Those credentials do not match our records.'),
            Response::HTTP_UNAUTHORIZED,
        );
    }
}
