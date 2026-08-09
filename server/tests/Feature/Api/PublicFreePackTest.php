<?php

namespace Tests\Feature\Api;

use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * Free packs are public (BL-52, DLC_SERVER.md §7.4).
 *
 * The product requirement in one sentence: *a signed-out child on a fresh
 * tablet can browse the shop and download every free book*. Every test here is
 * really the same question asked of a different route — and its mirror, which
 * matters just as much: **a paid pack did not move an inch**.
 */
class PublicFreePackTest extends TestCase
{
    use PublishesPacks, RefreshDatabase;

    public function test_a_free_manifest_needs_no_token_at_all(): void
    {
        $this->fakePackStorage();
        $version = $this->publishFixturePack(free: true);

        $manifest = $this->getJson('/api/v1/packs/forest-friends/manifest')
            ->assertOk()
            ->json();

        // Not a reduced "public" view: the document the zip shipped with,
        // because a client computes its delta from exactly this.
        $this->assertSame($version->manifest, $manifest);
    }

    public function test_a_free_download_still_302s_to_a_signed_url_that_streams_the_zip(): void
    {
        $this->fakePackStorage();
        $version = $this->publishFixturePack(free: true);

        $redirect = $this->get('/api/v1/packs/forest-friends/download');

        $redirect->assertStatus(302);
        $location = (string) $redirect->headers->get('Location');

        // The 302-to-signed-URL mechanics are untouched: the signature was
        // always the thing that moves bytes, and it still is.
        $this->assertStringContainsString('signature=', $location);
        $this->assertStringContainsString('/packs/forest-friends/v/1/archive', $location);

        $this->flushHeaders();
        $bytes = $this->get($location)->assertOk()->streamedContent();

        $this->assertSame($version->archive_sha256, hash('sha256', $bytes));
    }

    public function test_a_free_delta_file_needs_no_token(): void
    {
        $this->fakePackStorage();
        $version = $this->publishFixturePack(free: true);

        $path = 'books/coyote-2026/page_01_idmap.png';
        $expected = $version->files()[$path];

        $redirect = $this->get('/api/v1/packs/forest-friends/files/'.$path);
        $redirect->assertStatus(302);

        $this->flushHeaders();
        $bytes = $this->get((string) $redirect->headers->get('Location'))->assertOk()->streamedContent();

        $this->assertSame($expected['sha256'], hash('sha256', $bytes));
    }

    public function test_a_paid_pack_is_exactly_as_closed_as_it_was(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack();

        foreach ([
            '/api/v1/packs/forest-friends/manifest',
            '/api/v1/packs/forest-friends/download',
            '/api/v1/packs/forest-friends/files/books/coyote-2026/page_01.png',
        ] as $url) {
            $this->getJson($url)
                ->assertUnauthorized()
                ->assertJsonPath('error.code', 'UNAUTHENTICATED');
        }

        // …and signed in but unentitled is still the 403 the client hides the
        // pack's books on.
        $this->withToken($this->issueDeviceToken(User::factory()->create()))
            ->getJson('/api/v1/packs/forest-friends/download')
            ->assertForbidden()
            ->assertJsonPath('error.code', 'ENTITLEMENT_REQUIRED');
    }

    public function test_a_public_free_fetch_writes_no_row(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack(free: true);

        $this->get('/api/v1/packs/forest-friends/download')->assertRedirect();
        $this->get('/api/v1/packs/forest-friends/manifest')->assertOk();

        // Nobody asked; nobody is recorded. The anonymous tier is *lazy*
        // (§4.3): free play sends no identifier and creates no state.
        $this->assertSame(0, Entitlement::query()->count());
        $this->assertDatabaseCount('devices', 0);
    }

    public function test_the_free_claim_still_fires_when_a_token_happens_to_be_there(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack(free: true)->pack;

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->withToken($bearer)->get('/api/v1/packs/forest-friends/manifest')->assertOk();

        // `owned` and GET /entitlements keep meaning what they mean for a
        // signed-in household — the claim is no longer the *gate*, but it is
        // still the inventory.
        $this->assertDatabaseHas('entitlements', [
            'user_id' => $user->id,
            'device_id' => null,
            'pack_id' => $pack->id,
            'source' => Entitlement::SOURCE_FREE,
            'revoked_at' => null,
        ]);

        $this->withToken($bearer)->getJson('/api/v1/entitlements')
            ->assertOk()
            ->assertJsonCount(1)
            ->assertJsonPath('0.source', 'free');
    }

    public function test_a_retired_free_pack_stays_public_and_a_draft_one_is_invisible(): void
    {
        $this->fakePackStorage();
        $pack = $this->publishFixturePack(free: true)->pack;

        // Delisting must never take away books a household has (§7.3), and a
        // free pack's "household" is now everybody.
        $pack->update(['status' => Pack::STATUS_RETIRED]);
        $this->get('/api/v1/packs/forest-friends/download')->assertRedirect();

        // A draft is not a product, free or not.
        $pack->update(['status' => Pack::STATUS_DRAFT]);
        $this->getJson('/api/v1/packs/forest-friends/download')
            ->assertNotFound()
            ->assertJsonPath('error.code', 'NOT_FOUND');
    }

    public function test_the_manifest_allow_list_still_governs_a_public_delta(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack(free: true);

        // Public does not mean "the packs disk is a web root": a path is
        // servable only if the version's `files` map lists it.
        $this->getJson('/api/v1/packs/forest-friends/files/books/coyote-2026/page_99.png')
            ->assertNotFound()
            ->assertJsonPath('error.code', 'FILE_NOT_FOUND');

        foreach (['../../../.env', 'books/../../../.env'] as $attempt) {
            $response = $this->getJson('/api/v1/packs/forest-friends/files/'.$attempt);

            $this->assertNotSame(200, $response->getStatusCode(), $attempt.' was not refused');
        }
    }

    public function test_a_free_pack_serves_a_token_that_cannot_download(): void
    {
        $this->fakePackStorage();
        $this->publishFixturePack(free: true);

        $user = User::factory()->create();

        // `packs:download` gates *paid* bytes. A free pack skips the token gate
        // entirely, so a token that lacks the ability is no worse off than no
        // token at all — which is the only coherent answer once the same bytes
        // are one anonymous request away.
        $this->withToken($this->issueDeviceToken($user, 'tablet', ['save:sync']))
            ->get('/api/v1/packs/forest-friends/download')
            ->assertRedirect();
    }
}
