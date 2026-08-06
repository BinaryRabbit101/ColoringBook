<?php

namespace Tests\Concerns;

use Carbon\CarbonImmutable;
use Illuminate\Contracts\Filesystem\Filesystem;
use Illuminate\Support\Facades\Storage;
use Illuminate\Testing\TestResponse;

/**
 * Driving the paint endpoints the way the game does: negotiate, then PUT the
 * bytes to whatever URL the negotiation handed back.
 *
 * Nothing here hand-builds an upload URL or a digest header — `upload()` uses
 * the ones the `202` gave it, so every test that stores a picture also proves
 * the instructions in that response are usable.
 */
trait PaintsPages
{
    /**
     * Put the container back the way a fresh web request would find it.
     *
     * `auth:sanctum` calls `shouldUse('sanctum')`, which rewrites
     * `auth.defaults.guard` for the rest of the process. A real dashboard
     * request starts from a fresh container and never sees that; a test that
     * hits the API and then the dashboard does, and a bare `auth` middleware
     * would then quietly let a bearer token through a session-only route.
     * Call this in between.
     *
     * The guard name is spelled out rather than read back from config for
     * exactly the reason above: by this point config *is* the damage.
     */
    protected function useSessionGuard(): static
    {
        $this->app?->make('auth')->shouldUse('web');

        return $this->forgetResolvedGuards();
    }

    protected function fakePaintStorage(): Filesystem
    {
        return Storage::fake((string) config('coloringbook.storage.paint_disk'));
    }

    protected function paintDisk(): Filesystem
    {
        return Storage::disk((string) config('coloringbook.storage.paint_disk'));
    }

    /**
     * A PNG, as far as anything downstream is concerned: a real 1×1 image with
     * `$variant` appended so two calls differ in sha256 while both still carry
     * the PNG signature the upload path checks.
     */
    protected function png(string $variant = ''): string
    {
        $base = base64_decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
            true,
        );

        return ($base === false ? "\x89PNG\r\n\x1a\n" : $base).$variant;
    }

    /**
     * `POST /sync/paint/{book}/{page}` — the sha-first check.
     */
    protected function negotiate(
        string $bearer,
        string $bookUid,
        int $page,
        string $contents,
        ?CarbonImmutable $paintedAt = null,
        ?string $profile = null,
        ?int $bytes = null,
    ): TestResponse {
        $body = [
            'sha256' => hash('sha256', $contents),
            'bytes' => $bytes ?? strlen($contents),
            // Microseconds on the wire: the column keeps them and the LWW
            // tie-break turns on them, so a client that has them should send
            // them.
            'client_painted_at' => ($paintedAt ?? CarbonImmutable::now())->utc()->format('Y-m-d\TH:i:s.up'),
        ];

        if ($profile !== null) {
            $body['profile'] = $profile;
        }

        return $this->withToken($bearer)
            ->postJson("/api/v1/sync/paint/{$bookUid}/{$page}", $body);
    }

    /**
     * Negotiate and then, if the server asked for the bytes, send them.
     *
     * Returns the `PUT` response — or the `204` from the negotiation when the
     * server already had that picture and no upload happened.
     */
    protected function upload(
        string $bearer,
        string $bookUid,
        int $page,
        string $contents,
        ?CarbonImmutable $paintedAt = null,
        ?string $profile = null,
    ): TestResponse {
        $negotiation = $this->negotiate($bearer, $bookUid, $page, $contents, $paintedAt, $profile);

        if ($negotiation->getStatusCode() !== 202) {
            return $negotiation;
        }

        /** @var array{upload: array{url: string, headers: array<string, string>}} $body */
        $body = $negotiation->json();

        return $this->putRaw($bearer, $body['upload']['url'], $contents, $body['upload']['headers']);
    }

    /**
     * A raw-body PUT. `call()` does not apply the headers `withToken()` set, so
     * they are merged in by hand here.
     *
     * @param  array<string, string>  $headers
     */
    protected function putRaw(string $bearer, string $url, string $contents, array $headers = []): TestResponse
    {
        $headers = array_merge(
            ['Authorization' => 'Bearer '.$bearer, 'Accept' => 'application/json'],
            $headers,
        );

        return $this->call(
            'PUT',
            $url,
            [],
            [],
            [],
            $this->transformHeadersToServerVars($headers),
            $contents,
        );
    }

    /**
     * The RFC 9530 header for some bytes.
     */
    protected function contentDigest(string $contents): string
    {
        $raw = hex2bin(hash('sha256', $contents));

        return 'sha-256=:'.base64_encode($raw === false ? '' : $raw).':';
    }

    /**
     * The upload URL for a page, with the query the PUT expects.
     */
    protected function uploadUrl(
        string $bookUid,
        int $page,
        string $contents,
        ?CarbonImmutable $paintedAt = null,
        ?string $profile = null,
    ): string {
        $parameters = [
            'book_uid' => $bookUid,
            'page' => $page,
            'sha256' => hash('sha256', $contents),
            // Microseconds on the wire: the column keeps them and the LWW
            // tie-break turns on them, so a client that has them should send
            // them.
            'client_painted_at' => ($paintedAt ?? CarbonImmutable::now())->utc()->format('Y-m-d\TH:i:s.up'),
        ];

        if ($profile !== null) {
            $parameters['profile'] = $profile;
        }

        return route('api.v1.sync.paint.upload', $parameters);
    }
}
