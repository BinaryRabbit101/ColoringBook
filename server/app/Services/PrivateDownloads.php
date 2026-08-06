<?php

namespace App\Services;

use App\Exceptions\ApiException;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Facades\URL;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Response;

/**
 * Handing private bytes to a client that has already been authorised
 * (DLC_SERVER.md §7.4).
 *
 * Two steps, and they are separate on purpose:
 *
 * 1. The authorised route (token + ability + entitlement) does not send the
 *    file. It `302`s to a **short-lived signed URL** — `signedUrl()` below,
 *    10 minutes by config — so the actual transfer is a plain unauthenticated
 *    GET that `HTTPRequest.download_file` can stream straight to
 *    `user://dlc/<slug>.incoming/…` without minding headers.
 * 2. The signed route calls `serve()`, which either streams through PHP or,
 *    when `config('coloringbook.accel_redirect')` is on, answers with an
 *    `X-Accel-Redirect` header and lets Nginx push the bytes from an
 *    `internal;` location. An 8 MB pack should never occupy a PHP worker.
 *
 * Accel is **off by default**: `php artisan serve` has no Nginx in front of
 * it, so dev and the test suite take the streaming path and still exercise
 * every byte (SERVER_BUILD_PLAN.md, Decisions).
 */
class PrivateDownloads
{
    /**
     * A signed URL for one of our own routes, valid for the configured TTL.
     *
     * @param  array<string, mixed>  $parameters
     */
    public function signedUrl(string $routeName, array $parameters): string
    {
        return URL::temporarySignedRoute(
            $routeName,
            now()->addMinutes((int) config('coloringbook.signed_url_ttl_minutes')),
            $parameters,
        );
    }

    /**
     * Send `$path` from `$disk`, by whichever mechanism is configured.
     *
     * @param  string  $accelLocation  Key in `coloringbook.accel_locations`
     *                                 naming the Nginx `internal;` location
     *                                 that maps onto this disk's root.
     */
    public function serve(
        string $disk,
        string $path,
        string $downloadName,
        string $accelLocation,
        ?string $mime = null,
    ): Response {
        $filesystem = Storage::disk($disk);

        if (! $filesystem->exists($path)) {
            // The catalog promised a file the disk doesn't have. Say so
            // plainly: the client's move is to re-read the manifest, not to
            // retry this URL.
            throw new ApiException(
                'FILE_NOT_FOUND',
                __('That file is no longer available.'),
                Response::HTTP_NOT_FOUND,
            );
        }

        $mime ??= $this->mimeFor($path);

        if (config('coloringbook.accel_redirect') === true) {
            return $this->accelResponse($path, $downloadName, $accelLocation, $mime);
        }

        return $filesystem->download($path, $downloadName, [
            'Content-Type' => $mime,
        ]);
    }

    /**
     * The Nginx hand-off. PHP-FPM authorised the request and now answers with
     * an empty body plus the internal URI; Nginx replaces the body with the
     * file and sets its own `Content-Length`.
     *
     * Each segment is re-encoded because Nginx URL-decodes the header before
     * matching the location — a book title with a space in it would otherwise
     * resolve to the wrong file, or to nothing.
     */
    private function accelResponse(
        string $path,
        string $downloadName,
        string $accelLocation,
        string $mime,
    ): Response {
        /** @var array<string, string> $locations */
        $locations = config('coloringbook.accel_locations');
        $prefix = rtrim($locations[$accelLocation] ?? '/'.$accelLocation, '/');

        $encoded = implode('/', array_map(
            rawurlencode(...),
            explode('/', ltrim($path, '/')),
        ));

        return response('', Response::HTTP_OK, [
            'X-Accel-Redirect' => $prefix.'/'.$encoded,
            'X-Accel-Buffering' => 'yes',
            'Content-Type' => $mime,
            'Content-Disposition' => 'attachment; filename="'.$downloadName.'"',
        ]);
    }

    /**
     * The handful of types a pack is made of. Deliberately a fixed table, not
     * a sniff: these files are already content-addressed and validated on the
     * way in, and guessing from bytes we serve to a browser is a mistake.
     */
    private function mimeFor(string $path): string
    {
        return match (Str::lower(pathinfo($path, PATHINFO_EXTENSION))) {
            'zip' => 'application/zip',
            'png' => 'image/png',
            'json' => 'application/json',
            'jpg', 'jpeg' => 'image/jpeg',
            'webp' => 'image/webp',
            default => 'application/octet-stream',
        };
    }
}
