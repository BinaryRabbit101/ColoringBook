<?php

namespace Tests\Feature\Api;

use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\User;
use App\Services\PrivateDownloads;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Storage;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;
use ZipArchive;

/**
 * Manifest, download and delta delivery (DLC_SERVER.md §7.4, §11).
 *
 * Everything here runs against a pack published from the fixture through the
 * real publisher, so "the bytes the client receives" means exactly that.
 */
class PackDownloadTest extends TestCase
{
    use PublishesPacks, RefreshDatabase;

    public function test_a_download_needs_a_token(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack();

        $this->getJson('/api/v1/packs/forest-friends/download')
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'UNAUTHENTICATED');

        $this->getJson('/api/v1/packs/forest-friends/manifest')
            ->assertUnauthorized();
    }

    public function test_a_download_needs_the_packs_download_ability(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack();

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user, 'tablet', ['save:sync']);

        $this->withToken($bearer)
            ->getJson('/api/v1/packs/forest-friends/download')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'MISSING_ABILITY');
    }

    public function test_an_unowned_paid_pack_is_refused(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack();

        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/packs/forest-friends/download')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'ENTITLEMENT_REQUIRED');

        $this->assertSame(0, Entitlement::query()->count());
    }

    public function test_a_free_pack_grants_itself_on_the_first_download(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack(free: true)->pack;

        $user = User::factory()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->get('/api/v1/packs/forest-friends/download')
            ->assertRedirect();

        $this->assertDatabaseHas('entitlements', [
            'user_id' => $user->id,
            'pack_id' => $pack->id,
            'source' => Entitlement::SOURCE_FREE,
            'revoked_at' => null,
        ]);

        // Idempotent: asking twice is one row, not two (the unique index would
        // otherwise blow up a perfectly ordinary retry).
        $this->get('/api/v1/packs/forest-friends/download')->assertRedirect();
        $this->assertSame(1, Entitlement::query()->count());
    }

    public function test_a_revoked_entitlement_blocks_even_a_free_pack(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack(free: true)->pack;

        $user = User::factory()->create();
        Entitlement::factory()->for($user)->for($pack)->source(Entitlement::SOURCE_FREE)->revoked()->create();

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/packs/forest-friends/download')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'ENTITLEMENT_REQUIRED');

        // The auto-grant must not resurrect a deliberate revocation.
        $this->assertSame(1, Entitlement::query()->count());
        $this->assertNotNull(Entitlement::query()->sole()->revoked_at);
    }

    public function test_a_retired_pack_is_still_downloadable_by_its_owner(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;
        $pack->update(['status' => Pack::STATUS_RETIRED]);

        $user = User::factory()->create();
        Entitlement::factory()->for($user)->for($pack)->create();

        // Delisted from the shop...
        $this->getJson('/api/v1/packs/forest-friends')->assertNotFound();

        // ...but never taken away from a household that owns it (§7.3).
        $this->withToken($this->issueDeviceToken($user))
            ->get('/api/v1/packs/forest-friends/download')
            ->assertRedirect();
    }

    public function test_a_draft_pack_is_invisible_to_downloads_too(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack()->pack;
        $pack->update(['status' => Pack::STATUS_DRAFT]);

        $user = User::factory()->create();
        Entitlement::factory()->for($user)->for($pack)->create();

        $this->withToken($this->issueDeviceToken($user))
            ->getJson('/api/v1/packs/forest-friends/download')
            ->assertNotFound();
    }

    public function test_the_manifest_is_the_document_that_shipped_in_the_zip(): void
    {
        $this->fakePackStorage();
        $version = $this->publishFixturePack(free: true);

        $manifest = $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->getJson('/api/v1/packs/forest-friends/manifest')
            ->assertOk()
            ->json();

        $this->assertSame(1, $manifest['manifest_version']);
        $this->assertSame('forest-friends', $manifest['pack_slug']);
        // The server assigns the number, overwriting the builder's guess (3).
        $this->assertSame(1, $manifest['pack_version']);
        $this->assertSame('0.7.0', $manifest['min_client_version']);
        $this->assertSame($version->manifest, $manifest);

        // The per-file map is what makes a delta possible (§7.2), and it
        // carries the synthesised book.json files too.
        $this->assertArrayHasKey('books/coyote-2026/page_01.png', $manifest['files']);
        $this->assertArrayHasKey('books/coyote-2026/book.json', $manifest['files']);
    }

    public function test_the_download_redirects_to_a_signed_url_that_streams_the_exact_zip(): void
    {
        $this->fakePackStorage();
        $version = $this->publishFixturePack(free: true);

        $redirect = $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->get('/api/v1/packs/forest-friends/download');

        $redirect->assertStatus(302);
        $location = (string) $redirect->headers->get('Location');
        $this->assertStringContainsString('signature=', $location);
        $this->assertStringContainsString('/packs/forest-friends/v/1/archive', $location);

        // The signature is the whole authorisation: no bearer token needed,
        // which is what lets HTTPRequest.download_file stream straight to disk.
        $this->flushHeaders();
        $response = $this->get($location);

        $response->assertOk();
        $bytes = $response->streamedContent();

        $this->assertSame($version->archive_bytes, strlen($bytes));
        $this->assertSame($version->archive_sha256, hash('sha256', $bytes));

        // And it really is the pack: manifest plus every file it lists.
        $this->assertZipContains($bytes, array_merge(
            ['manifest.json'],
            array_keys($version->files()),
        ));
    }

    public function test_a_signed_download_link_stops_working_after_ten_minutes(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack(free: true);

        $location = (string) $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->get('/api/v1/packs/forest-friends/download')
            ->headers->get('Location');

        $this->flushHeaders();
        $this->travel(9)->minutes();
        $this->get($location)->assertOk();

        $this->travel(2)->minutes();
        $this->getJson($location)
            ->assertForbidden()
            ->assertJsonPath('error.code', 'DOWNLOAD_LINK_EXPIRED');
    }

    public function test_a_tampered_signed_link_is_refused(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack(free: true);
        $this->publishFixturePack(free: true); // v2 exists

        $location = (string) $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->get('/api/v1/packs/forest-friends/download?version=1')
            ->headers->get('Location');

        $this->flushHeaders();
        $this->getJson(str_replace('/v/1/', '/v/2/', $location))
            ->assertForbidden()
            ->assertJsonPath('error.code', 'DOWNLOAD_LINK_EXPIRED');
    }

    public function test_the_delta_route_serves_one_file_with_matching_bytes(): void
    {
        $this->fakePackStorage();
        $version = $this->publishFixturePack(free: true);

        $path = 'books/coyote-2026/page_01_idmap.png';
        $expected = $version->files()[$path];

        $redirect = $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->get('/api/v1/packs/forest-friends/files/'.$path);

        $redirect->assertStatus(302);

        $this->flushHeaders();
        $response = $this->get((string) $redirect->headers->get('Location'));

        $response->assertOk();
        $bytes = $response->streamedContent();

        // The ID map must arrive byte-identical or region ids are corrupt.
        $this->assertSame($expected['bytes'], strlen($bytes));
        $this->assertSame($expected['sha256'], hash('sha256', $bytes));
        $this->assertSame('image/png', $response->headers->get('Content-Type'));
    }

    public function test_the_delta_route_only_serves_paths_the_manifest_lists(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack(free: true);

        $bearer = $this->issueDeviceToken(User::factory()->create());

        $this->withToken($bearer)
            ->getJson('/api/v1/packs/forest-friends/files/books/coyote-2026/page_99.png')
            ->assertNotFound()
            ->assertJsonPath('error.code', 'FILE_NOT_FOUND');
    }

    public function test_the_delta_route_rejects_path_traversal(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack(free: true);

        $bearer = $this->issueDeviceToken(User::factory()->create());

        foreach ([
            '../../../.env',
            'books/../../../.env',
            '%2e%2e%2f%2e%2e%2f.env',
            'books/coyote-2026/../../../../.env',
        ] as $attempt) {
            $response = $this->withToken($bearer)
                ->getJson('/api/v1/packs/forest-friends/files/'.$attempt);

            $this->assertNotSame(200, $response->getStatusCode(), $attempt.' was not refused');
        }

        // And the signed half refuses it even with a valid signature, because
        // the manifest allow-list — not the signature — decides what exists.
        $this->flushHeaders();
        $signed = app(PrivateDownloads::class)->signedUrl('api.v1.packs.file.signed', [
            'slug' => 'forest-friends',
            'version' => 1,
            'path' => 'nope/secrets.env',
        ]);

        $this->getJson($signed)
            ->assertNotFound()
            ->assertJsonPath('error.code', 'FILE_NOT_FOUND');
    }

    public function test_an_unpublished_version_cannot_be_asked_for(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack(free: true);

        $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->getJson('/api/v1/packs/forest-friends/download?version=7')
            ->assertNotFound()
            ->assertJsonPath('error.code', 'PACK_VERSION_NOT_FOUND');
    }

    public function test_an_explicit_version_pins_the_download_to_that_release(): void
    {
        $this->fakePackStorage();
        $first = $this->publishFixturePack(free: true);
        $second = $this->publishFixturePack(free: true);

        $this->assertSame(1, $first->version);
        $this->assertSame(2, $second->version);

        $bearer = $this->issueDeviceToken(User::factory()->create());

        $location = (string) $this->withToken($bearer)
            ->get('/api/v1/packs/forest-friends/download?version=1')
            ->headers->get('Location');

        $this->flushHeaders();
        $bytes = $this->get($location)->streamedContent();

        $this->assertSame($first->archive_sha256, hash('sha256', $bytes));

        // …and no ?version= means the newest release.
        $this->withToken($bearer);
        $latest = (string) $this->get('/api/v1/packs/forest-friends/download')
            ->headers->get('Location');

        $this->assertStringContainsString('/v/2/archive', $latest);
    }

    public function test_accel_redirect_hands_the_bytes_to_nginx_instead_of_streaming(): void
    {
        $this->fakePackStorage();
        $version = $this->publishFixturePack(free: true);

        config(['coloringbook.accel_redirect' => true]);

        $location = (string) $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->get('/api/v1/packs/forest-friends/download')
            ->headers->get('Location');

        $this->flushHeaders();
        $response = $this->get($location);

        $response->assertOk();
        // PHP-FPM authorised and got out of the way: empty body, and an
        // internal URI for Nginx to serve from (§7.4).
        $this->assertSame('', $response->getContent());
        $this->assertSame(
            '/_packs/'.$version->archive_path,
            $response->headers->get('X-Accel-Redirect'),
        );
        $this->assertSame('application/zip', $response->headers->get('Content-Type'));
    }

    public function test_a_missing_archive_on_disk_is_reported_not_streamed_as_nothing(): void
    {
        $this->fakePackStorage();
        $version = $this->publishFixturePack(free: true);

        Storage::disk((string) config('coloringbook.storage.packs_disk'))
            ->delete($version->archive_path);

        $location = (string) $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->get('/api/v1/packs/forest-friends/download')
            ->headers->get('Location');

        $this->flushHeaders();
        $this->getJson($location)
            ->assertNotFound()
            ->assertJsonPath('error.code', 'FILE_NOT_FOUND');
    }

    public function test_versions_are_monotonic_and_never_rewritten(): void
    {
        $this->fakePackStorage();

        $first = $this->publishFixturePack();
        $second = $this->publishFixturePack();
        $third = $this->publishFixturePack();

        $this->assertSame([1, 2, 3], [$first->version, $second->version, $third->version]);
        $this->assertSame(3, PackVersion::query()->count());

        // v1's row and its archive are exactly as published.
        $reloaded = $first->fresh();
        $this->assertNotNull($reloaded);
        $this->assertSame($first->archive_sha256, $reloaded->archive_sha256);
        $this->assertSame('forest-friends/v1/pack.zip', $reloaded->archive_path);

        Storage::disk((string) config('coloringbook.storage.packs_disk'))
            ->assertExists(['forest-friends/v1/pack.zip', 'forest-friends/v2/pack.zip', 'forest-friends/v3/pack.zip']);
    }

    /**
     * @param  array<int, string>  $expected
     */
    private function assertZipContains(string $bytes, array $expected): void
    {
        $temporary = (string) tempnam(sys_get_temp_dir(), 'zip');
        file_put_contents($temporary, $bytes);

        try {
            $zip = new ZipArchive;
            $this->assertTrue($zip->open($temporary) === true, 'the download is not a readable zip');

            $found = [];

            for ($i = 0; $i < $zip->numFiles; $i++) {
                $found[] = (string) $zip->getNameIndex($i);
            }

            $zip->close();

            foreach ($expected as $path) {
                $this->assertContains($path, $found);
            }

            $this->assertCount(count($expected), $found);
        } finally {
            unlink($temporary);
        }
    }
}
