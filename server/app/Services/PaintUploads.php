<?php

namespace App\Services;

use App\Exceptions\ApiException;
use App\Http\Requests\Sync\UploadPaintRequest;
use Carbon\CarbonImmutable;
use Symfony\Component\HttpFoundation\Response;

/**
 * Everything that has to be true about a paint upload before it is allowed to
 * displace a child's picture (DLC_SERVER.md §6.3).
 *
 * ### The clock
 *
 * Progress **clamps** a wrong client clock; paint **rejects** it. The
 * divergence is deliberate and worth keeping: a save must never fail because
 * a tablet's date is wrong, but a picture stamped three years in the future
 * would win last-write-wins forever and bury every later drawing behind it.
 * Rejecting is recoverable — the client retries once its clock is sane, and
 * meanwhile nothing has been lost.
 *
 * ### The digest
 *
 * Two checks, not one. `Content-Digest` proves the bytes arrived intact, and
 * the negotiated `sha256` proves they are the bytes the `POST` agreed to
 * move. A truncated upload fails the first; a client that hashed one page and
 * uploaded another fails the second. Either way the row's `sha256` column is
 * genuinely the digest of the file on disk, which is what makes the
 * "already have it" negotiation trustworthy.
 */
class PaintUploads
{
    /**
     * The PNG magic number. Checked because the sha-first negotiation makes
     * this column authoritative for "the server already has that picture", and
     * because a blob served back to a client that trusts the extension should
     * be what it claims to be.
     */
    private const PNG_SIGNATURE = "\x89PNG\r\n\x1a\n";

    /**
     * Read the body, prove it is what was promised, hand back a value.
     */
    public function read(UploadPaintRequest $request): PaintUpload
    {
        $contents = $request->getContent();
        $bytes = strlen($contents);

        $this->assertSize($bytes);

        if (! str_starts_with($contents, self::PNG_SIGNATURE)) {
            throw new ApiException(
                'PAINT_NOT_PNG',
                __('A paint layer must be a PNG.'),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $declared = $request->bodyDigest();

        if ($declared === null) {
            throw new ApiException(
                'DIGEST_MISSING',
                __('A paint upload must carry a Content-Digest header naming its sha-256.'),
                Response::HTTP_BAD_REQUEST,
            );
        }

        $actual = hash('sha256', $contents);
        $negotiated = $request->negotiatedSha256();

        if (! hash_equals($actual, $declared) || ! hash_equals($actual, $negotiated)) {
            throw new ApiException(
                'DIGEST_MISMATCH',
                __('Those bytes do not match the digest that was agreed for this page.'),
                Response::HTTP_UNPROCESSABLE_ENTITY,
                ['sha256' => $actual],
            );
        }

        return new PaintUpload(
            sha256: $actual,
            bytes: $bytes,
            contents: $contents,
            clientPaintedAt: $this->sane($request->clientPaintedAt()),
        );
    }

    /**
     * A client clock more than the skew window ahead of ours is refused, with
     * the server's own time so the device can correct itself.
     */
    public function sane(CarbonImmutable $clientPaintedAt): CarbonImmutable
    {
        $hours = (int) config('coloringbook.paint.max_clock_skew_hours');
        $limit = CarbonImmutable::now()->addHours($hours);

        if ($clientPaintedAt->greaterThan($limit)) {
            throw new ApiException(
                'PAINT_CLOCK_SKEW',
                __('That painting time is too far in the future to be real.'),
                Response::HTTP_UNPROCESSABLE_ENTITY,
                [
                    'server_time' => CarbonImmutable::now()->utc()->format('Y-m-d\TH:i:s.up'),
                    'max_clock_skew_hours' => $hours,
                ],
            );
        }

        return $clientPaintedAt;
    }

    public function maxBytes(): int
    {
        return (int) config('coloringbook.paint.max_bytes');
    }

    /**
     * Refuse anything past the cap, and anything empty.
     */
    public function assertSize(int $bytes): void
    {
        if ($bytes === 0) {
            throw new ApiException(
                'PAINT_EMPTY',
                __('That upload had no body.'),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        if ($bytes > $this->maxBytes()) {
            throw new ApiException(
                'PAINT_TOO_LARGE',
                __('That paint layer is larger than this server accepts.'),
                Response::HTTP_REQUEST_ENTITY_TOO_LARGE,
                ['max_bytes' => $this->maxBytes()],
            );
        }
    }
}
