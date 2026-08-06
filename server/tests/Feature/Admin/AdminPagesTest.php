<?php

namespace Tests\Feature\Admin;

use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Tests\Concerns\AdminsPacks;
use Tests\Concerns\PublishesPacks;
use Tests\TestCase;

/**
 * The Inertia half — session auth, same actions, same validation.
 *
 * The gating assertion that matters is the **404**: a parent who guesses
 * `/admin/packs` must not learn the section exists, and the sidebar renders no
 * link to it either (AppSidebar.vue reads `auth.user.is_admin`).
 */
class AdminPagesTest extends TestCase
{
    use AdminsPacks, PublishesPacks, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakePackStorage();
    }

    public function test_a_signed_out_visitor_is_sent_to_login(): void
    {
        $this->get('/admin/packs')->assertRedirect(route('login'));
    }

    public function test_an_ordinary_parent_gets_a_404_not_a_403(): void
    {
        $user = User::factory()->create();

        $this->actingAs($user)->get('/admin/packs')->assertNotFound();
        $this->actingAs($user)->get('/admin/entitlements')->assertNotFound();
        $this->actingAs($user)->post('/admin/packs', [
            'slug' => 'sneaky',
            'title' => 'Sneaky',
        ])->assertNotFound();

        $this->assertSame(0, Pack::query()->count());
    }

    public function test_the_pack_list_shows_drafts(): void
    {
        Pack::factory()->create(['slug' => 'meadow-mates', 'title' => 'Meadow Mates']);

        $this->actingAs(User::factory()->admin()->create())
            ->get('/admin/packs')
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('admin/Packs')
                ->has('packs', 1)
                ->where('packs.0.slug', 'meadow-mates'),
            );
    }

    public function test_an_admin_creates_a_pack_from_the_form(): void
    {
        $this->actingAs(User::factory()->admin()->create())
            ->post('/admin/packs', ['slug' => 'meadow-mates', 'title' => 'Meadow Mates'])
            ->assertSessionHasNoErrors()
            ->assertRedirect('/admin/packs/meadow-mates');

        $this->assertSame(Pack::STATUS_DRAFT, Pack::query()->sole()->status);
    }

    public function test_uploading_previewing_and_publishing_through_the_browser(): void
    {
        $admin = User::factory()->admin()->create();
        Pack::factory()->create(['slug' => 'meadow-mates', 'title' => 'Meadow Mates']);

        $this->actingAs($admin)
            ->post('/admin/packs/meadow-mates/versions', ['archive' => $this->packUpload()])
            ->assertSessionHasNoErrors()
            ->assertRedirect('/admin/packs/meadow-mates');

        $this->actingAs($admin)
            ->get('/admin/packs/meadow-mates')
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('admin/Pack')
                ->has('versions', 1)
                ->where('versions.0.status', 'draft')
                ->where('validationErrors', []),
            );

        $this->actingAs($admin)
            ->get('/admin/packs/meadow-mates/versions/1/preview')
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('admin/Preview')
                ->has('pages', 2),
            );

        $image = $this->actingAs($admin)
            ->get('/admin/packs/meadow-mates/versions/1/preview/meadow-2026/1')
            ->assertOk();

        $this->assertSame('image/png', $image->headers->get('Content-Type'));
        $this->assertNotFalse(@imagecreatefromstring($image->getContent()));

        $this->actingAs($admin)
            ->post('/admin/packs/meadow-mates/versions/1/publish')
            ->assertRedirect('/admin/packs/meadow-mates');

        $this->assertNotNull(PackVersion::query()->sole()->published_at);
        $this->assertSame(Pack::STATUS_PUBLISHED, Pack::query()->sole()->status);
    }

    public function test_a_pack_that_fails_validation_bounces_with_the_whole_list(): void
    {
        $admin = User::factory()->admin()->create();
        Pack::factory()->create(['slug' => 'meadow-mates']);

        // A zip with nothing in it: no manifest, so nothing to validate.
        $empty = (string) tempnam(sys_get_temp_dir(), 'emptyzip');
        $zip = new \ZipArchive;
        $zip->open($empty, \ZipArchive::CREATE | \ZipArchive::OVERWRITE);
        $zip->addFromString('readme.txt', 'not a pack');
        $zip->close();

        $this->actingAs($admin)
            ->post('/admin/packs/meadow-mates/versions', [
                'archive' => new UploadedFile($empty, 'pack.zip', 'application/zip', null, true),
            ])
            ->assertRedirect('/admin/packs/meadow-mates')
            ->assertSessionHas('pack_errors');

        $this->assertSame(0, PackVersion::query()->count());
    }

    public function test_an_admin_grants_an_entitlement_from_the_form(): void
    {
        $admin = User::factory()->admin()->create();
        User::factory()->create(['email' => 'parent@example.com']);
        Pack::factory()->create(['slug' => 'meadow-mates']);

        $this->actingAs($admin)
            ->get('/admin/entitlements')
            ->assertOk()
            ->assertInertia(fn ($page) => $page
                ->component('admin/Entitlements')
                ->has('packs', 1)
                ->has('sources'),
            );

        $this->actingAs($admin)
            ->post('/admin/entitlements', [
                'email' => 'parent@example.com',
                'pack_slug' => 'meadow-mates',
            ])
            ->assertSessionHasNoErrors()
            ->assertRedirect('/admin/entitlements');

        $this->assertSame(1, Entitlement::query()->count());
    }

    public function test_an_unknown_email_comes_back_as_a_field_error(): void
    {
        $admin = User::factory()->admin()->create();
        Pack::factory()->create(['slug' => 'meadow-mates']);

        $this->actingAs($admin)
            ->from('/admin/entitlements')
            ->post('/admin/entitlements', [
                'email' => 'nobody@example.com',
                'pack_slug' => 'meadow-mates',
            ])
            ->assertSessionHasErrors('email');
    }
}
