<?php

namespace Tests\Feature\Api;

use App\Models\Asset;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Tests\Concerns\AdminsPacks;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * `/api/v1/admin/*` — the token door onto the publishing tool (§10, §11).
 *
 * The shape of these tests follows the flow the design describes, because the
 * flow *is* the feature: upload → validate → draft → preview → publish. Every
 * step in between must leave the pack invisible to `GET /packs`.
 */
class AdminPackTest extends TestCase
{
    use AdminsPacks, PublishesPacks, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakePackStorage();
    }

    // ------------------------------------------------------------- gating --

    public function test_a_game_token_cannot_reach_the_admin_api(): void
    {
        // The full game ability set — and none of it is `admin`.
        $this->withToken($this->issueDeviceToken())
            ->getJson('/api/v1/admin/packs')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'MISSING_ABILITY');
    }

    public function test_an_admin_ability_token_on_a_non_admin_account_is_forbidden(): void
    {
        $user = User::factory()->create();

        $this->withToken($this->adminToken($user))
            ->getJson('/api/v1/admin/packs')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'FORBIDDEN');
    }

    public function test_the_admin_api_needs_a_token_at_all(): void
    {
        $this->getJson('/api/v1/admin/packs')
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'UNAUTHENTICATED');
    }

    // ------------------------------------------------------------- assets --

    public function test_uploading_the_same_asset_twice_is_idempotent(): void
    {
        $token = $this->adminToken();
        $path = $this->adminPackFixturePath().'/books/meadow-2026/page_01.png';

        $first = $this->withToken($token)->post('/api/v1/admin/assets', [
            'file' => new UploadedFile($path, 'page_01.png', 'image/png', null, true),
            'kind' => 'display',
        ])->assertCreated();

        $second = $this->withToken($token)->post('/api/v1/admin/assets', [
            'file' => new UploadedFile($path, 'page_01.png', 'image/png', null, true),
            'kind' => 'display',
        ])->assertCreated();

        $this->assertSame($first->json('asset_ulid'), $second->json('asset_ulid'));
        $this->assertSame(hash_file('sha256', $path), $first->json('sha256'));
        $this->assertSame(1, Asset::query()->count());
    }

    public function test_the_same_bytes_in_a_second_role_are_a_second_row(): void
    {
        $token = $this->adminToken();
        $path = $this->adminPackFixturePath().'/cover.png';

        foreach (['cover', 'display'] as $kind) {
            $this->withToken($token)->post('/api/v1/admin/assets', [
                'file' => new UploadedFile($path, 'cover.png', 'image/png', null, true),
                'kind' => $kind,
            ])->assertCreated();
        }

        // One blob on disk, two roles in the catalog.
        $this->assertSame(2, Asset::query()->count());
        $this->assertSame(1, Asset::query()->distinct()->count('sha256'));
    }

    public function test_an_unknown_asset_kind_is_rejected(): void
    {
        $this->withToken($this->adminToken())->postJson('/api/v1/admin/assets', [
            'kind' => 'sprite',
        ])->assertStatus(422)->assertJsonPath('error.code', 'VALIDATION_FAILED');
    }

    // -------------------------------------------------------------- packs --

    public function test_an_admin_creates_a_draft_pack(): void
    {
        $this->withToken($this->adminToken())->postJson('/api/v1/admin/packs', [
            'slug' => 'meadow-mates',
            'title' => 'Meadow Mates',
            'blurb' => 'One little book.',
            'is_free' => true,
        ])->assertCreated()->assertJsonPath('pack.status', Pack::STATUS_DRAFT);

        $this->assertSame(Pack::STATUS_DRAFT, Pack::query()->sole()->status);

        // …and a draft pack is not a product.
        $this->getJson('/api/v1/packs')->assertOk()->assertJsonCount(0, 'packs');
    }

    public function test_a_slug_that_is_not_slug_shaped_is_rejected(): void
    {
        $this->withToken($this->adminToken())->postJson('/api/v1/admin/packs', [
            'slug' => 'Meadow Mates',
            'title' => 'Meadow Mates',
        ])->assertStatus(422)->assertJsonPath('error.code', 'VALIDATION_FAILED');
    }

    // ------------------------------------------- the draft → publish flow --

    public function test_a_zip_upload_becomes_a_draft_then_publishes(): void
    {
        $token = $this->adminToken();
        $this->createPack($token);

        $created = $this->withToken($token)
            ->post('/api/v1/admin/packs/meadow-mates/versions', ['archive' => $this->packUpload()])
            ->assertCreated()
            ->assertJsonPath('status', 'draft')
            ->assertJsonPath('errors', []);

        $this->assertSame(1, $created->json('version'));

        $version = PackVersion::query()->sole();
        $this->assertNull($version->published_at);
        $this->assertSame(Pack::STATUS_DRAFT, $version->pack->status);

        // Invisible everywhere a player could look.
        $this->getJson('/api/v1/packs')->assertOk()->assertJsonCount(0, 'packs');
        $this->getJson('/api/v1/packs/meadow-mates')->assertNotFound();

        // The reviewer's step: the page list, then an actual overlay.
        $preview = $this->withToken($token)
            ->getJson('/api/v1/admin/packs/meadow-mates/versions/1/preview')
            ->assertOk()
            ->assertJsonCount(2, 'pages');

        $this->assertSame('meadow-2026', $preview->json('pages.0.book_uid'));

        $image = $this->withToken($token)
            ->get('/api/v1/admin/packs/meadow-mates/versions/1/preview/meadow-2026/0')
            ->assertOk();

        $this->assertSame('image/png', $image->headers->get('Content-Type'));
        $this->assertNotFalse(@imagecreatefromstring($image->getContent()));

        // …and only now is it a product.
        $this->withToken($token)
            ->postJson('/api/v1/admin/packs/meadow-mates/versions/1/publish')
            ->assertOk()
            ->assertJsonPath('version.status', 'published');

        $this->assertSame(Pack::STATUS_PUBLISHED, Pack::query()->sole()->status);

        $this->getJson('/api/v1/packs')
            ->assertOk()
            ->assertJsonCount(1, 'packs')
            ->assertJsonPath('packs.0.slug', 'meadow-mates')
            ->assertJsonPath('packs.0.latest_version', 1);
    }

    public function test_a_published_version_can_never_be_published_again(): void
    {
        $token = $this->adminToken();
        $this->createPack($token);
        $this->uploadDraft($token);

        $this->withToken($token)
            ->postJson('/api/v1/admin/packs/meadow-mates/versions/1/publish')
            ->assertOk();

        $this->withToken($token)
            ->postJson('/api/v1/admin/packs/meadow-mates/versions/1/publish')
            ->assertStatus(409)
            ->assertJsonPath('error.code', 'PACK_VERSION_ALREADY_PUBLISHED');
    }

    public function test_uploading_again_assigns_the_next_version_and_leaves_the_first_alone(): void
    {
        $token = $this->adminToken();
        $this->createPack($token);
        $this->uploadDraft($token);

        $this->withToken($token)
            ->postJson('/api/v1/admin/packs/meadow-mates/versions/1/publish')
            ->assertOk();

        $this->withToken($token)
            ->post('/api/v1/admin/packs/meadow-mates/versions', ['archive' => $this->packUpload()])
            ->assertCreated()
            ->assertJsonPath('version', 2)
            ->assertJsonPath('status', 'draft');

        $this->assertNotNull(PackVersion::query()->where('version', 1)->sole()->published_at);
        $this->assertNull(PackVersion::query()->where('version', 2)->sole()->published_at);

        // A draft v2 must not become what the game downloads.
        $this->getJson('/api/v1/packs')->assertJsonPath('packs.0.latest_version', 1);
    }

    public function test_a_manifest_plus_asset_ulids_is_the_other_accepted_form(): void
    {
        $token = $this->adminToken();
        $this->createPack($token);

        $manifest = $this->fixtureManifest();
        $assets = [];

        /** @var array<string, mixed> $files */
        $files = $manifest['files'];

        foreach (array_keys($files) as $path) {
            $absolute = $this->adminPackFixturePath().DIRECTORY_SEPARATOR
                .str_replace('/', DIRECTORY_SEPARATOR, (string) $path);

            $assets[$path] = $this->withToken($token)->post('/api/v1/admin/assets', [
                'file' => new UploadedFile($absolute, basename((string) $path), null, null, true),
                'kind' => str_ends_with((string) $path, '.json') ? 'regions' : 'display',
            ])->assertCreated()->json('asset_ulid');
        }

        $this->withToken($token)
            ->postJson('/api/v1/admin/packs/meadow-mates/versions', [
                'manifest' => $manifest,
                'assets' => $assets,
            ])
            ->assertCreated()
            ->assertJsonPath('version', 1)
            ->assertJsonPath('status', 'draft');
    }

    public function test_a_pack_whose_pixels_disagree_is_refused_with_every_reason(): void
    {
        $token = $this->adminToken();
        $this->createPack($token);

        $directory = $this->brokenPackDirectory();

        $response = $this->withToken($token)
            ->post('/api/v1/admin/packs/meadow-mates/versions', ['archive' => $this->packUpload($directory)])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'PACK_VALIDATION_FAILED');

        /** @var array<int, string> $errors */
        $errors = $response->json('error.details.errors');

        $this->assertNotEmpty($errors);
        $this->assertStringContainsString('absent from the regions JSON', implode(' ', $errors));

        // Nothing was created: a rejected pack leaves no half-made release.
        $this->assertSame(0, PackVersion::query()->count());
    }

    public function test_an_archive_containing_a_traversal_path_is_refused(): void
    {
        $token = $this->adminToken();
        $this->createPack($token);

        $path = (string) tempnam(sys_get_temp_dir(), 'evilzip');
        $zip = new \ZipArchive;
        $zip->open($path, \ZipArchive::CREATE | \ZipArchive::OVERWRITE);
        $zip->addFromString('../../.env', 'APP_KEY=stolen');
        $zip->close();

        $this->withToken($token)
            ->post('/api/v1/admin/packs/meadow-mates/versions', [
                'archive' => new UploadedFile($path, 'pack.zip', 'application/zip', null, true),
            ])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'PACK_VALIDATION_FAILED');

        $this->assertSame(0, PackVersion::query()->count());
    }

    public function test_a_version_for_an_unknown_pack_is_a_404(): void
    {
        $this->withToken($this->adminToken())
            ->post('/api/v1/admin/packs/nobody-home/versions', ['archive' => $this->packUpload()])
            ->assertNotFound();
    }

    // ------------------------------------------------------------ helpers --

    private function createPack(string $token): void
    {
        $this->withToken($token)->postJson('/api/v1/admin/packs', [
            'slug' => 'meadow-mates',
            'title' => 'Meadow Mates',
        ])->assertCreated();
    }

    private function uploadDraft(string $token): void
    {
        $this->withToken($token)
            ->post('/api/v1/admin/packs/meadow-mates/versions', ['archive' => $this->packUpload()])
            ->assertCreated();
    }

    /**
     * A copy of the fixture whose page-one regions JSON has lost a region —
     * the classic "the JSON and the PNG came from different runs".
     */
    private function brokenPackDirectory(): string
    {
        $target = storage_path('app/private/testing/broken-'.bin2hex(random_bytes(4)));
        $source = $this->adminPackFixturePath();

        /** @var iterable<\SplFileInfo> $files */
        $files = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($source, \FilesystemIterator::SKIP_DOTS),
        );

        foreach ($files as $file) {
            if (! $file->isFile()) {
                continue;
            }

            $relative = ltrim(str_replace($source, '', $file->getPathname()), '/\\');
            $destination = $target.DIRECTORY_SEPARATOR.$relative;

            if (! is_dir(dirname($destination))) {
                mkdir(dirname($destination), 0775, true);
            }

            copy($file->getPathname(), $destination);
        }

        $regionsPath = $target.'/books/meadow-2026/page_01_regions.json';

        /** @var array{regions: array<int, mixed>} $regions */
        $regions = json_decode((string) file_get_contents($regionsPath), true);
        array_pop($regions['regions']);
        file_put_contents($regionsPath, (string) json_encode($regions));

        // Re-stamp the manifest so the *structural* validator stays quiet and
        // the pixel checks are what actually fires.
        $manifestPath = $target.'/manifest.json';

        /** @var array<string, mixed> $manifest */
        $manifest = json_decode((string) file_get_contents($manifestPath), true);

        /** @var array<string, array{bytes: int, sha256: string}> $files */
        $files = $manifest['files'];
        $files['books/meadow-2026/page_01_regions.json'] = [
            'bytes' => (int) filesize($regionsPath),
            'sha256' => (string) hash_file('sha256', $regionsPath),
        ];
        $manifest['files'] = $files;

        file_put_contents($manifestPath, (string) json_encode($manifest));

        return $target;
    }
}
