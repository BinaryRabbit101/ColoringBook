<?php

namespace App\Http\Middleware;

use App\Exceptions\ApiException;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * The signature *is* the authorisation on a download URL (DLC_SERVER.md §7.4).
 *
 * Laravel's built-in `signed` middleware answers a stale link with a bare 403.
 * A game client needs to tell "your link went stale, ask for another" apart
 * from "you don't own this", because the first is a silent retry and the
 * second must hide the pack — so this raises a code of its own instead.
 *
 * Ten minutes (`coloringbook.signed_url_ttl_minutes`) is long enough for an
 * 8 MB download to *start*; the transfer itself is not re-checked.
 */
class VerifySignedDownload
{
    public function handle(Request $request, Closure $next): Response
    {
        if (! $request->hasValidSignature()) {
            throw new ApiException(
                'DOWNLOAD_LINK_EXPIRED',
                __('That download link is no longer valid. Please request a new one.'),
                Response::HTTP_FORBIDDEN,
            );
        }

        return $next($request);
    }
}
