<?php

namespace Tests\Feature\Api;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\PaintLayer;
use App\Models\RetainedPaintLayer;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\PaintsPages;
use Tests\TestCase;

/**
 * `/api/v1/sync/paint` — DLC_SERVER.md §11 "Sync", §6.2–6.3.
 *
 * Paint is the half of sync that moves megabytes, so most of what is proved
 * here is about *not* moving them: the sha-first negotiation, the digest
 * checks, and last-write-wins deciding a race without ever asking a child a
 * question.
 */
class PaintSyncTest extends TestCase
{
    use PaintsPages, RefreshDatabase;

    // ------------------------------------------------------------- the gate

    public function test_paint_needs_a_token(): void
    {
        $this->postJson('/api/v1/sync/paint/coyote-2026/0', [
            'sha256' => hash('sha256', 'x'),
            'bytes' => 1,
            'client_painted_at' => CarbonImmutable::now()->toIso8601String(),
        ])->assertUnauthorized()->assertJsonPath('error.code', 'UNAUTHENTICATED');

        $this->getJson('/api/v1/sync/paint/coyote-2026/0')->assertUnauthorized();
        $this->getJson('/api/v1/sync/paint/coyote-2026')->assertUnauthorized();
    }

    public function test_paint_needs_the_save_sync_ability(): void
    {
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user, 'tablet', ['packs:download']);

        $this->negotiate($bearer, 'coyote-2026', 0, $this->png())
            ->assertForbidden()
            ->assertJsonPath('error.code', 'MISSING_ABILITY');

        $this->withToken($bearer)->getJson('/api/v1/sync/paint/coyote-2026/0')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'MISSING_ABILITY');

        $this->putRaw($bearer, $this->uploadUrl('coyote-2026', 0, $this->png()), $this->png())
            ->assertForbidden()
            ->assertJsonPath('error.code', 'MISSING_ABILITY');
    }

    // ------------------------------------------------------- the negotiation

    public function test_a_page_the_server_has_never_seen_asks_for_the_bytes(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $response = $this->negotiate($this->issueDeviceToken($user), 'coyote-2026', 0, $this->png());

        $response->assertAccepted()
            ->assertJsonPath('server', null)
            ->assertJsonPath('upload.method', 'PUT')
            ->assertJsonPath('upload.max_bytes', (int) config('coloringbook.paint.max_bytes'))
            ->assertJsonPath('upload.headers.Content-Type', 'image/png')
            ->assertJsonPath('upload.headers.Content-Digest', $this->contentDigest($this->png()));

        $this->assertStringContainsString(
            '/api/v1/sync/paint/coyote-2026/0',
            (string) $response->json('upload.url'),
        );

        // Negotiating writes nothing at all.
        $this->assertDatabaseCount('book_progress', 0);
        $this->assertDatabaseCount('paint_layers', 0);
    }

    public function test_a_digest_the_server_already_holds_needs_no_upload(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('one'))->assertCreated();

        $layer = PaintLayer::query()->sole();

        // A second device offering the identical picture, and claiming a much
        // newer clock: still nothing to do.
        $this->negotiate($bearer, 'coyote-2026', 0, $this->png('one'), CarbonImmutable::now()->addHour())
            ->assertNoContent();

        $layer->refresh();

        // Read-only: no revision burned, no timestamp advanced.
        $this->assertSame(1, $layer->revision);
        $this->assertDatabaseCount('paint_layers', 1);
        $this->assertDatabaseCount('retained_paint_layers', 0);
    }

    public function test_the_negotiation_describes_what_would_be_displaced(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('one'))->assertCreated();

        $this->negotiate($bearer, 'coyote-2026', 0, $this->png('two'))
            ->assertAccepted()
            ->assertJsonPath('server.sha256', hash('sha256', $this->png('one')))
            ->assertJsonPath('server.revision', 1)
            ->assertJsonPath('server.page_index', 0);
    }

    public function test_a_clock_more_than_a_day_ahead_is_refused_rather_than_clamped(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $this->negotiate(
            $this->issueDeviceToken($user),
            'coyote-2026',
            0,
            $this->png(),
            CarbonImmutable::now()->addHours(25),
        )
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'PAINT_CLOCK_SKEW')
            ->assertJsonPath('error.details.max_clock_skew_hours', 24);
    }

    public function test_a_clock_inside_the_skew_window_is_accepted(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $this->upload(
            $this->issueDeviceToken($user),
            'coyote-2026',
            0,
            $this->png(),
            CarbonImmutable::now()->addHours(23),
        )->assertCreated();
    }

    public function test_an_upload_bigger_than_the_cap_is_refused_before_it_starts(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $this->negotiate(
            $this->issueDeviceToken($user),
            'coyote-2026',
            0,
            $this->png(),
            bytes: (int) config('coloringbook.paint.max_bytes') + 1,
        )
            ->assertStatus(413)
            ->assertJsonPath('error.code', 'PAINT_TOO_LARGE');
    }

    public function test_a_page_beyond_any_real_book_is_refused(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $this->negotiate($this->issueDeviceToken($user), 'coyote-2026', 5000, $this->png())
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'PAGE_OUT_OF_RANGE');
    }

    // ------------------------------------------------------------ the upload

    public function test_an_upload_stores_the_png_where_the_design_says(): void
    {
        $disk = $this->fakePaintStorage();
        $user = User::factory()->create();

        $this->upload($this->issueDeviceToken($user), 'coyote-2026', 0, $this->png('one'))
            ->assertCreated()
            ->assertExactJson(['revision' => 1]);

        // paint/<user_ulid>/<book_uid>/page_NN.png — and NN is 1-based, like
        // the file the client already writes to user://paint/.
        $path = "{$user->ulid}/coyote-2026/page_01.png";

        $disk->assertExists($path);
        $this->assertSame($this->png('one'), $disk->get($path));

        $layer = PaintLayer::query()->sole();
        $this->assertSame($path, $layer->storage_path);
        $this->assertSame(hash('sha256', $this->png('one')), $layer->sha256);
        $this->assertSame(strlen($this->png('one')), $layer->bytes);
        $this->assertSame(1, $layer->revision);
    }

    public function test_the_first_upload_for_a_book_creates_its_progress_row(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $this->assertDatabaseCount('book_progress', 0);

        $this->upload($this->issueDeviceToken($user), 'coyote-2026', 2, $this->png())
            ->assertCreated();

        $progress = BookProgress::query()->sole();

        $this->assertSame('coyote-2026', $progress->book_uid);
        $this->assertSame(1, $progress->revision);
        $this->assertSame([], $progress->pageStatuses());
        $this->assertNull($progress->child_profile_id);
        $this->assertSame($progress->id, PaintLayer::query()->sole()->book_progress_id);
    }

    public function test_a_second_page_reuses_the_progress_row(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('a'))->assertCreated();
        $this->upload($bearer, 'coyote-2026', 1, $this->png('b'))->assertCreated();

        $this->assertDatabaseCount('book_progress', 1);
        $this->assertDatabaseCount('paint_layers', 2);
    }

    public function test_paint_does_not_wake_every_other_device_through_the_progress_cursor(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $progress = BookProgress::factory()->for($user)->create(['book_uid' => 'coyote-2026']);
        $touched = $progress->updated_at;

        $this->travel(2)->seconds();

        $this->upload($this->issueDeviceToken($user), 'coyote-2026', 0, $this->png())->assertCreated();

        $this->assertEquals($touched, $progress->refresh()->updated_at);
    }

    // ------------------------------------------------------------ the digest

    public function test_bytes_that_do_not_match_the_content_digest_are_refused(): void
    {
        $disk = $this->fakePaintStorage();
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        // The digest and the URL both describe one picture; the body is another.
        $this->putRaw(
            $bearer,
            $this->uploadUrl('coyote-2026', 0, $this->png('promised')),
            $this->png('delivered'),
            ['Content-Digest' => $this->contentDigest($this->png('promised'))],
        )
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'DIGEST_MISMATCH');

        $this->assertDatabaseCount('paint_layers', 0);
        $this->assertEmpty($disk->allFiles());
    }

    public function test_a_body_that_does_not_match_the_negotiated_digest_is_refused(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        // Header and body agree with each other, but not with what was agreed.
        $this->putRaw(
            $this->issueDeviceToken($user),
            $this->uploadUrl('coyote-2026', 0, $this->png('negotiated')),
            $this->png('something else'),
            ['Content-Digest' => $this->contentDigest($this->png('something else'))],
        )
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'DIGEST_MISMATCH');

        $this->assertDatabaseCount('paint_layers', 0);
    }

    public function test_an_upload_with_no_digest_header_is_refused(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $this->putRaw(
            $this->issueDeviceToken($user),
            $this->uploadUrl('coyote-2026', 0, $this->png()),
            $this->png(),
        )
            ->assertStatus(400)
            ->assertJsonPath('error.code', 'DIGEST_MISSING');
    }

    public function test_the_older_rfc_3230_digest_header_is_accepted_too(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $this->putRaw(
            $this->issueDeviceToken($user),
            $this->uploadUrl('coyote-2026', 0, $this->png()),
            $this->png(),
            ['Digest' => 'SHA-256='.base64_encode((string) hex2bin(hash('sha256', $this->png())))],
        )->assertCreated();
    }

    public function test_something_that_is_not_a_png_is_refused(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();
        $body = 'GIF89a not really a picture';

        $this->putRaw(
            $this->issueDeviceToken($user),
            $this->uploadUrl('coyote-2026', 0, $body),
            $body,
            ['Content-Digest' => $this->contentDigest($body)],
        )
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'PAINT_NOT_PNG');
    }

    public function test_a_body_over_the_size_cap_is_refused(): void
    {
        $this->fakePaintStorage();
        config(['coloringbook.paint.max_bytes' => 64]);

        $user = User::factory()->create();
        $body = $this->png(str_repeat('x', 200));

        $this->putRaw(
            $this->issueDeviceToken($user),
            $this->uploadUrl('coyote-2026', 0, $body),
            $body,
            ['Content-Digest' => $this->contentDigest($body)],
        )
            ->assertStatus(413)
            ->assertJsonPath('error.code', 'PAINT_TOO_LARGE')
            ->assertJsonPath('error.details.max_bytes', 64);

        $this->assertDatabaseCount('paint_layers', 0);
    }

    // ------------------------------------------------------ last-write-wins

    public function test_the_newer_picture_wins_and_the_older_one_is_retained(): void
    {
        $disk = $this->fakePaintStorage();
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $morning = CarbonImmutable::parse('2026-08-06 09:00:00');

        $this->upload($bearer, 'coyote-2026', 0, $this->png('morning'), $morning)->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('evening'), $morning->addHours(9))
            ->assertCreated()
            ->assertExactJson(['revision' => 2]);

        $layer = PaintLayer::query()->sole();
        $this->assertSame(hash('sha256', $this->png('evening')), $layer->sha256);
        $this->assertSame(2, $layer->revision);

        // The live file is the winner…
        $this->assertSame($this->png('evening'), $disk->get("{$user->ulid}/coyote-2026/page_01.png"));

        // …and the loser is beside it, suffixed with the revision it held.
        $retained = RetainedPaintLayer::query()->sole();
        $this->assertSame("{$user->ulid}/coyote-2026/page_01.1.png", $retained->storage_path);
        $this->assertSame(1, $retained->revision);
        $this->assertSame(hash('sha256', $this->png('morning')), $retained->sha256);
        $this->assertSame($this->png('morning'), $disk->get($retained->storage_path));
    }

    public function test_the_older_picture_loses_and_is_told_so(): void
    {
        $disk = $this->fakePaintStorage();
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $evening = CarbonImmutable::parse('2026-08-06 18:00:00');

        $this->upload($bearer, 'coyote-2026', 0, $this->png('evening'), $evening)->assertCreated();

        $this->upload($bearer, 'coyote-2026', 0, $this->png('morning'), $evening->subHours(9))
            ->assertStatus(409)
            ->assertJsonPath('error.code', 'PAINT_STALE')
            ->assertJsonPath('error.details.server.sha256', hash('sha256', $this->png('evening')))
            ->assertJsonPath('error.details.server.revision', 1);

        // Nothing was written, and nothing was retained either.
        $this->assertSame(1, PaintLayer::query()->sole()->revision);
        $this->assertDatabaseCount('retained_paint_layers', 0);
        $this->assertSame($this->png('evening'), $disk->get("{$user->ulid}/coyote-2026/page_01.png"));
        $this->assertCount(1, $disk->allFiles());
    }

    public function test_an_exact_tie_goes_to_the_write_that_arrives_second(): void
    {
        $disk = $this->fakePaintStorage();
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        // Same client timestamp to the microsecond. §6.3 makes the server
        // clock the tie-break, and by the server's clock this one is later.
        $sameMoment = CarbonImmutable::parse('2026-08-06 12:00:00.123456');

        $this->upload($bearer, 'coyote-2026', 0, $this->png('first'), $sameMoment)->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('second'), $sameMoment)
            ->assertCreated()
            ->assertExactJson(['revision' => 2]);

        $this->assertSame($this->png('second'), $disk->get("{$user->ulid}/coyote-2026/page_01.png"));
    }

    public function test_a_hundred_microseconds_is_enough_to_decide_the_race(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $at = CarbonImmutable::parse('2026-08-06 12:00:00.500000');

        $this->upload($bearer, 'coyote-2026', 0, $this->png('later'), $at)->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('earlier'), $at->subMicroseconds(100))
            ->assertStatus(409)
            ->assertJsonPath('error.code', 'PAINT_STALE');
    }

    public function test_re_uploading_the_same_bytes_burns_no_revision(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('one'))->assertCreated();

        // Straight at the PUT, skipping the negotiation that would have
        // answered 204 — the same answer has to come out of the upload path.
        $this->putRaw(
            $bearer,
            $this->uploadUrl('coyote-2026', 0, $this->png('one')),
            $this->png('one'),
            ['Content-Digest' => $this->contentDigest($this->png('one'))],
        )->assertNoContent();

        $this->assertSame(1, PaintLayer::query()->sole()->revision);
        $this->assertDatabaseCount('retained_paint_layers', 0);
    }

    public function test_an_upload_from_a_wildly_future_clock_is_refused(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();
        $future = CarbonImmutable::now()->addYear();

        $this->putRaw(
            $this->issueDeviceToken($user),
            $this->uploadUrl('coyote-2026', 0, $this->png(), $future),
            $this->png(),
            ['Content-Digest' => $this->contentDigest($this->png())],
        )
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'PAINT_CLOCK_SKEW');

        $this->assertDatabaseCount('paint_layers', 0);
    }

    // ----------------------------------------------------------- the shelves

    public function test_a_child_shelf_and_the_account_shelf_hold_separate_pictures(): void
    {
        $disk = $this->fakePaintStorage();
        $user = User::factory()->create();
        $profile = ChildProfile::factory()->for($user)->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('everyone'))->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('ivy'), profile: $profile->ulid)->assertCreated();

        // Two shelves, two files, and neither is a revision of the other.
        $disk->assertExists("{$user->ulid}/coyote-2026/page_01.png");
        $disk->assertExists("{$user->ulid}/{$profile->ulid}/coyote-2026/page_01.png");

        $this->assertSame($this->png('everyone'), $disk->get("{$user->ulid}/coyote-2026/page_01.png"));
        $this->assertSame($this->png('ivy'), $disk->get("{$user->ulid}/{$profile->ulid}/coyote-2026/page_01.png"));

        $this->assertDatabaseCount('paint_layers', 2);
        $this->assertDatabaseCount('retained_paint_layers', 0);
        $this->assertDatabaseCount('book_progress', 2);
    }

    public function test_a_profile_that_is_not_yours_is_a_404(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();
        $stranger = ChildProfile::factory()->for(User::factory())->create();

        $this->negotiate($this->issueDeviceToken($user), 'coyote-2026', 0, $this->png(), profile: $stranger->ulid)
            ->assertNotFound()
            ->assertJsonPath('error.code', 'NOT_FOUND');
    }

    public function test_another_households_picture_is_invisible(): void
    {
        $this->fakePaintStorage();
        $painter = User::factory()->create();
        $stranger = User::factory()->create();

        $this->upload($this->issueDeviceToken($painter, 'painter'), 'coyote-2026', 0, $this->png())
            ->assertCreated();

        $this->forgetResolvedGuards()
            ->withToken($this->issueDeviceToken($stranger, 'stranger'))
            ->getJson('/api/v1/sync/paint/coyote-2026/0')
            ->assertNotFound()
            ->assertJsonPath('error.code', 'PAINT_NOT_FOUND');
    }

    // ---------------------------------------------------------- the download

    public function test_fetching_a_page_redirects_to_a_signed_url_that_serves_the_bytes(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 1, $this->png('picture'))->assertCreated();

        $redirect = $this->withToken($bearer)->get('/api/v1/sync/paint/coyote-2026/1');
        $redirect->assertStatus(302);

        $signed = (string) $redirect->headers->get('Location');
        $this->assertStringContainsString('/api/v1/sync/paint-blob/', $signed);

        // No token on the transfer itself: the signature is the authorisation,
        // so HTTPRequest.download_file can stream it straight to disk.
        $blob = $this->get($signed);

        $blob->assertOk();
        $this->assertSame($this->png('picture'), $blob->streamedContent());
        $this->assertSame('image/png', $blob->headers->get('Content-Type'));
        $this->assertStringContainsString('page_02.png', (string) $blob->headers->get('Content-Disposition'));
    }

    public function test_an_unsigned_blob_url_is_refused(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $this->upload($this->issueDeviceToken($user), 'coyote-2026', 0, $this->png())->assertCreated();

        $layer = PaintLayer::query()->sole();

        $this->getJson("/api/v1/sync/paint-blob/{$layer->ulid}")
            ->assertForbidden()
            ->assertJsonPath('error.code', 'DOWNLOAD_LINK_EXPIRED');
    }

    public function test_an_expired_signature_is_refused(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png())->assertCreated();

        $signed = (string) $this->withToken($bearer)
            ->get('/api/v1/sync/paint/coyote-2026/0')
            ->headers->get('Location');

        $this->travel((int) config('coloringbook.signed_url_ttl_minutes') + 1)->minutes();

        $this->getJson($signed)
            ->assertForbidden()
            ->assertJsonPath('error.code', 'DOWNLOAD_LINK_EXPIRED');
    }

    public function test_an_unpainted_page_is_a_404(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/sync/paint/coyote-2026/3')
            ->assertNotFound()
            ->assertJsonPath('error.code', 'PAINT_NOT_FOUND');
    }

    // ---------------------------------------------------------- the metadata

    public function test_the_book_summary_lists_every_painted_page(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('a'))->assertCreated();
        $this->upload($bearer, 'coyote-2026', 2, $this->png('c'))->assertCreated();

        $this->withToken($bearer)
            ->getJson('/api/v1/sync/paint/coyote-2026')
            ->assertOk()
            ->assertJsonPath('book_uid', 'coyote-2026')
            ->assertJsonCount(2, 'pages')
            ->assertJsonPath('pages.0.page_index', 0)
            ->assertJsonPath('pages.0.sha256', hash('sha256', $this->png('a')))
            ->assertJsonPath('pages.1.page_index', 2)
            ->assertJsonStructure([
                'book_uid',
                'pages' => [['page_index', 'sha256', 'bytes', 'revision', 'client_painted_at']],
                'server_time',
            ]);
    }

    public function test_the_book_summary_of_an_unsynced_book_is_empty_rather_than_missing(): void
    {
        $this->fakePaintStorage();
        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/sync/paint/never-opened')
            ->assertOk()
            ->assertJsonCount(0, 'pages');
    }
}
