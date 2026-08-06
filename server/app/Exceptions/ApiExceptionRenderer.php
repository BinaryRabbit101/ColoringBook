<?php

namespace App\Exceptions;

use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Auth\AuthenticationException;
use Illuminate\Database\Eloquent\ModelNotFoundException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Validation\ValidationException;
use Laravel\Sanctum\Exceptions\MissingAbilityException;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Exception\HttpExceptionInterface;
use Symfony\Component\HttpKernel\Exception\MethodNotAllowedHttpException;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;
use Throwable;

/**
 * The single place `/api/*` failures become the house error shape.
 *
 *     {"error": {"code": "SNAKE_CASE_CODE", "message": "…"}}
 *
 * Validation failures carry an extra `details` map of field → messages. Wired
 * up in `bootstrap/app.php`; every work package inherits it for free, so no
 * controller should ever hand-roll an error body (DLC_SERVER.md §11).
 *
 * Web/Inertia responses are left completely alone — this only ever fires for
 * request paths under `/api`.
 */
class ApiExceptionRenderer
{
    /**
     * HTTP status → stable client-facing code, for exceptions that carry a
     * status but no opinion of their own (`abort(404)`, router 405s, …).
     *
     * @var array<int, string>
     */
    private const STATUS_CODES = [
        400 => 'BAD_REQUEST',
        401 => 'UNAUTHENTICATED',
        403 => 'FORBIDDEN',
        404 => 'NOT_FOUND',
        405 => 'METHOD_NOT_ALLOWED',
        409 => 'CONFLICT',
        410 => 'GONE',
        413 => 'PAYLOAD_TOO_LARGE',
        415 => 'UNSUPPORTED_MEDIA_TYPE',
        419 => 'PAGE_EXPIRED',
        422 => 'VALIDATION_FAILED',
        429 => 'THROTTLED',
        500 => 'SERVER_ERROR',
        503 => 'SERVICE_UNAVAILABLE',
    ];

    /**
     * Render the exception, or return null to let Laravel handle it normally.
     */
    public function __invoke(Throwable $e, Request $request): ?JsonResponse
    {
        if (! $request->is('api/*')) {
            return null;
        }

        [$status, $code, $message, $details] = $this->describe($e);

        $error = ['code' => $code, 'message' => $message];

        if ($details !== null) {
            $error['details'] = $details;
        }

        return new JsonResponse(['error' => $error], $status, $this->headers($e));
    }

    /**
     * Reduce any throwable to [status, code, message, details].
     *
     * Laravel converts a few exception types before render callbacks run —
     * an `AuthorizationException` arrives as an `AccessDeniedHttpException`,
     * a `ModelNotFoundException` as a `NotFoundHttpException` — carrying the
     * original as `previous`. Unwrapping it is what lets a Sanctum ability
     * failure keep its own code instead of collapsing into a generic 403.
     *
     * @return array{0: int, 1: string, 2: string, 3: array<string, mixed>|null}
     */
    private function describe(Throwable $e): array
    {
        $original = $e instanceof HttpExceptionInterface
            ? ($e->getPrevious() ?? $e)
            : $e;

        if ($e instanceof ApiException) {
            return [
                $e->status,
                $e->errorCode,
                $e->getMessage(),
                $e->details === [] ? null : $e->details,
            ];
        }

        if ($original instanceof MissingAbilityException) {
            return [
                Response::HTTP_FORBIDDEN,
                'MISSING_ABILITY',
                __('This token is not allowed to perform that action.'),
                null,
            ];
        }

        if ($original instanceof ModelNotFoundException || $e instanceof NotFoundHttpException) {
            return [
                Response::HTTP_NOT_FOUND,
                'NOT_FOUND',
                // Never the framework's prose here: "No query results for
                // model [App\Models\ChildProfile] 01J…" names our internals.
                __('The requested resource does not exist.'),
                null,
            ];
        }

        if ($e instanceof MethodNotAllowedHttpException) {
            return [
                Response::HTTP_METHOD_NOT_ALLOWED,
                'METHOD_NOT_ALLOWED',
                __('That method is not supported for this endpoint.'),
                null,
            ];
        }

        if ($e instanceof ValidationException) {
            return [
                $e->status,
                'VALIDATION_FAILED',
                __('The given data was invalid.'),
                $e->errors(),
            ];
        }

        if ($e instanceof AuthenticationException) {
            return [
                Response::HTTP_UNAUTHORIZED,
                'UNAUTHENTICATED',
                __('This action requires a valid access token.'),
                null,
            ];
        }

        if ($e instanceof AuthorizationException) {
            return [
                Response::HTTP_FORBIDDEN,
                'FORBIDDEN',
                $this->prose($e->getMessage(), __('This action is unauthorized.')),
                null,
            ];
        }

        if ($e instanceof HttpExceptionInterface) {
            $status = $e->getStatusCode();

            return [
                $status,
                self::STATUS_CODES[$status] ?? 'HTTP_ERROR',
                $this->prose($e->getMessage(), $this->defaultMessage($status)),
                null,
            ];
        }

        // Anything genuinely unexpected. The prose is generic in production so
        // stack-trace detail never leaks to a game client.
        return [
            Response::HTTP_INTERNAL_SERVER_ERROR,
            'SERVER_ERROR',
            config('app.debug') === true
                ? $e->getMessage()
                : __('Something went wrong. Please try again.'),
            null,
        ];
    }

    /**
     * Headers the underlying exception wants preserved — `Retry-After` and the
     * `X-RateLimit-*` family on a throttle, mainly.
     *
     * @return array<string, string|array<int, string>>
     */
    private function headers(Throwable $e): array
    {
        return $e instanceof HttpExceptionInterface ? $e->getHeaders() : [];
    }

    private function prose(string $message, string $fallback): string
    {
        return trim($message) === '' ? $fallback : $message;
    }

    private function defaultMessage(int $status): string
    {
        return match ($status) {
            401 => __('This action requires a valid access token.'),
            403 => __('This action is unauthorized.'),
            404 => __('The requested resource does not exist.'),
            405 => __('That method is not supported for this endpoint.'),
            429 => __('Too many requests. Please slow down.'),
            503 => __('The service is temporarily unavailable.'),
            default => __('The request could not be completed.'),
        };
    }
}
