<?php

namespace App\Http\Controllers\Api\V1;

use App\Actions\Sync\StorePaintLayer;
use App\Exceptions\ApiException;
use App\Http\Controllers\Controller;
use App\Http\Requests\Sync\NegotiatePaintRequest;
use App\Http\Requests\Sync\UploadPaintRequest;
use App\Http\Resources\PaintLayerResource;
use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\PaintLayer;
use App\Models\User;
use App\Services\PaintStorage;
use App\Services\PaintUploads;
use App\Services\PrivateDownloads;
use Carbon\CarbonImmutable;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * `/api/v1/sync/paint` — DLC_SERVER.md §11 "Sync", §6.2–6.3.
 *
 * Paint is the lazy half of sync: 0.5–2 MB per page against progress's 200
 * bytes, uploaded only for pages a child actually touched and pulled only when
 * a page is opened on a device that hasn't got it (§6.2). So the protocol is
 * built to move as few bytes as possible.
 *
 * ### The three steps
 *
 * 1. `POST .../{book_uid}/{page}` with `{sha256, bytes, client_painted_at}`.
 *    If the server already holds that digest for that page it answers `204`
 *    and the upload never happens. Otherwise `202` with the exact request the
 *    client should make next — URL, headers and the size cap.
 * 2. `PUT` the raw PNG to that URL. The digest is checked twice (see
 *    `PaintUploads`), then last-write-wins decides (see `StorePaintLayer`).
 *    `201 {revision}` on a write; `204` if those bytes turn out to be what is
 *    already stored; `409 PAINT_STALE` with the server's metadata if the
 *    upload is the older picture.
 * 3. `GET .../{book_uid}/{page}` answers `302` to a ten-minute signed URL, or
 *    `404 PAINT_NOT_FOUND`. The bytes themselves move over the signed route,
 *    with no bearer token, so Godot's `HTTPRequest.download_file` can stream
 *    straight to `user://paint/…` — the same mechanism WP3 uses for packs.
 *
 * `GET .../{book_uid}` (no page) is the cheap "has the server got newer?"
 * check: every painted page of one book as metadata only. It exists so the
 * client never has to guess, and so `GET /sync/progress` could stay exactly
 * the shape WP2 defined.
 *
 * ### The negotiation is read-only
 *
 * `POST` writes nothing — no row, no timestamp, not even when it answers
 * `204`. A device that re-negotiates on every launch therefore costs one small
 * query, and two devices negotiating at once cannot interleave into anything.
 * The `book_progress` row is created by the `PUT`, when there is actually a
 * picture to hang off it.
 */
class PaintSyncController extends Controller
{
    public function __construct(
        private readonly PaintUploads $uploads,
        private readonly PaintStorage $storage,
        private readonly PrivateDownloads $downloads,
    ) {}

    /**
     * Every painted page of one book — metadata only, no pixels.
     */
    public function index(Request $request, string $bookUid): JsonResponse
    {
        $user = $this->user($request);
        $profile = $this->profile($user, $this->profileUlid($request));

        $progress = $this->shelf($user, $profile, $bookUid);

        $layers = $progress === null
            ? collect()
            : PaintLayer::query()
                ->where('book_progress_id', $progress->id)
                ->orderBy('page_index')
                ->get();

        return response()->json([
            'book_uid' => $bookUid,
            'pages' => PaintLayerResource::collection($layers),
            'server_time' => CarbonImmutable::now()->utc()->format('Y-m-d\TH:i:s.up'),
        ]);
    }

    /**
     * The sha-first check: have you already got this picture?
     */
    public function negotiate(NegotiatePaintRequest $request, string $bookUid, int $page): JsonResponse
    {
        $user = $this->user($request);
        $profile = $this->profile($user, $request->profileUlid());

        $this->assertPageInRange($page);
        $this->uploads->assertSize($request->bytes());
        $this->uploads->sane($request->clientPaintedAt());

        $layer = $this->layer($user, $profile, $bookUid, $page);

        if ($layer !== null && hash_equals($layer->sha256, $request->sha256())) {
            // Nothing to say and nothing to do — and deliberately no write:
            // the picture on the server is byte-for-byte the one the client is
            // offering, so there is no sense in which either is newer.
            return response()->json(null, Response::HTTP_NO_CONTENT);
        }

        return response()->json([
            'upload' => $this->uploadInstructions($request, $bookUid, $page),
            // What the client would be displacing, so a device that has been
            // offline for a week can decide for itself rather than discover
            // the conflict halfway through a 2 MB upload.
            'server' => $layer === null ? null : PaintLayerResource::describe($layer),
        ], Response::HTTP_ACCEPTED);
    }

    /**
     * The upload itself: raw PNG in, last-write-wins out.
     */
    public function upload(
        UploadPaintRequest $request,
        string $bookUid,
        int $page,
        StorePaintLayer $store,
    ): JsonResponse {
        $user = $this->user($request);
        $profile = $this->profile($user, $request->profileUlid());

        $this->assertPageInRange($page);

        $outcome = $store->handle($user, $profile, $bookUid, $page, $this->uploads->read($request));

        if (! $outcome->written) {
            return response()->json(null, Response::HTTP_NO_CONTENT);
        }

        return response()->json(
            ['revision' => $outcome->layer->revision],
            Response::HTTP_CREATED,
        );
    }

    /**
     * `302` to a signed URL for the pixels, or `404`.
     */
    public function show(Request $request, string $bookUid, int $page): RedirectResponse
    {
        $user = $this->user($request);
        $profile = $this->profile($user, $this->profileUlid($request));

        $layer = $this->layer($user, $profile, $bookUid, $page);

        if ($layer === null) {
            throw new ApiException(
                'PAINT_NOT_FOUND',
                __('There is no picture on that page yet.'),
                Response::HTTP_NOT_FOUND,
            );
        }

        return redirect()->away(
            $this->downloads->signedUrl('api.v1.sync.paint.blob', ['layer' => $layer->ulid]),
            Response::HTTP_FOUND,
        );
    }

    /**
     * The signed endpoint that actually moves the PNG. No token: the
     * signature is the authorisation, exactly as for pack downloads (§7.4).
     *
     * A link resolves to whatever is current when it is redeemed. Within its
     * ten-minute life another device could win a LWW race and change that;
     * the client checks the digest it receives against the one it asked for,
     * and re-asks if they differ.
     */
    public function blob(PaintLayer $layer): Response
    {
        return $this->downloads->serve(
            (string) config('coloringbook.storage.paint_disk'),
            $layer->storage_path,
            $this->storage->fileName($layer->page_index),
            'paint',
            'image/png',
        );
    }

    /**
     * The `PUT` the client should make next, spelled out so it never has to
     * assemble a URL or guess a header format.
     *
     * @return array<string, mixed>
     */
    private function uploadInstructions(NegotiatePaintRequest $request, string $bookUid, int $page): array
    {
        $raw = hex2bin($request->sha256());

        $parameters = [
            'book_uid' => $bookUid,
            'page' => $page,
            'sha256' => $request->sha256(),
            'client_painted_at' => $request->clientPaintedAt()->format('Y-m-d\TH:i:s.up'),
        ];

        if ($request->profileUlid() !== null) {
            $parameters['profile'] = $request->profileUlid();
        }

        return [
            'method' => 'PUT',
            'url' => route('api.v1.sync.paint.upload', $parameters),
            'headers' => [
                'Content-Type' => 'image/png',
                'Content-Digest' => 'sha-256=:'.base64_encode($raw === false ? '' : $raw).':',
            ],
            'max_bytes' => $this->uploads->maxBytes(),
        ];
    }

    /**
     * One page's current layer, or null — scoped to the shelf, so another
     * child's picture is not merely forbidden but invisible.
     */
    private function layer(User $user, ?ChildProfile $profile, string $bookUid, int $page): ?PaintLayer
    {
        $progress = $this->shelf($user, $profile, $bookUid);

        if ($progress === null) {
            return null;
        }

        return PaintLayer::query()
            ->where('book_progress_id', $progress->id)
            ->where('page_index', $page)
            ->first();
    }

    private function shelf(User $user, ?ChildProfile $profile, string $bookUid): ?BookProgress
    {
        return BookProgress::query()
            ->where('user_id', $user->id)
            ->forProfile($profile)
            ->where('book_uid', $bookUid)
            ->first();
    }

    /**
     * A guard rail, not a product limit — the same one `PUT /sync/progress`
     * applies to `page_statuses`, so the two halves of a shelf agree on how
     * big a book can be.
     */
    private function assertPageInRange(int $page): void
    {
        $max = (int) config('coloringbook.sync.max_pages_per_book');

        if ($page < 0 || $page >= $max) {
            throw new ApiException(
                'PAGE_OUT_OF_RANGE',
                __('That page number is outside any book this server stores.'),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }
    }

    /**
     * Absent `profile` is the account-level shelf; a ULID that isn't one of
     * *this* user's children is a 404, never a 403 (WP2's rule).
     */
    private function profile(User $user, ?string $ulid): ?ChildProfile
    {
        if ($ulid === null) {
            return null;
        }

        return $user->childProfiles()->where('ulid', $ulid)->firstOrFail();
    }

    private function profileUlid(Request $request): ?string
    {
        $profile = $request->query('profile');

        return is_string($profile) && $profile !== '' ? $profile : null;
    }

    private function user(Request $request): User
    {
        $user = $request->user();

        abort_unless($user instanceof User, Response::HTTP_UNAUTHORIZED);

        return $user;
    }
}
