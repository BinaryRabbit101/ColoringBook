<?php

namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Tests\TestCase;

/**
 * WP0 guardrails: the pieces every later work package builds on.
 */
class ScaffoldTest extends TestCase
{
    use RefreshDatabase;

    public function test_a_user_is_minted_with_a_ulid_and_is_not_an_admin(): void
    {
        $user = User::factory()->create();

        $this->assertTrue(Str::isUlid($user->ulid));
        $this->assertFalse($user->is_admin);
        $this->assertSame('ulid', $user->getRouteKeyName());
    }

    public function test_an_explicit_ulid_is_not_overwritten(): void
    {
        $ulid = (string) Str::ulid();

        $user = User::factory()->create(['ulid' => $ulid]);

        $this->assertSame($ulid, $user->ulid);
    }

    public function test_the_admin_factory_state_flips_is_admin(): void
    {
        $this->assertTrue(User::factory()->admin()->create()->is_admin);
    }

    public function test_the_private_content_disks_are_rooted_per_design_section_five(): void
    {
        foreach (['packs', 'assets'] as $disk) {
            $this->assertSame(
                storage_path('app/private/'.$disk),
                config("filesystems.disks.{$disk}.root"),
            );

            // Never web-readable: authorisation always goes through a controller.
            $this->assertFalse(config("filesystems.disks.{$disk}.serve"));

            Storage::disk($disk); // resolves without throwing
        }
    }

    /**
     * Publishing and serving are two different Unix users on the deployed box
     * (the operator over SSH, then PHP-FPM). Flysystem's 0700/0600 default makes
     * a freshly published pack unreadable — and un-traversable — to the process
     * that has to serve it, which surfaces as FILE_NOT_FOUND on every download.
     */
    public function test_the_private_disks_write_group_readable_files_and_directories(): void
    {
        foreach (['packs', 'assets'] as $disk) {
            $this->assertSame(
                0640,
                config("filesystems.disks.{$disk}.permissions.file.private"),
            );

            // The directory bit is the one that bites: without +x on the group,
            // the bytes inside are unreachable however readable they are.
            $this->assertSame(
                0750,
                config("filesystems.disks.{$disk}.permissions.dir.private"),
            );

            // Private means private: nothing here is world-anything.
            $this->assertSame(0, config("filesystems.disks.{$disk}.permissions.file.private") & 0007);
            $this->assertSame(0, config("filesystems.disks.{$disk}.permissions.dir.private") & 0007);
        }
    }

    public function test_accel_redirect_is_off_by_default(): void
    {
        $this->assertFalse(config('coloringbook.accel_redirect'));
        $this->assertSame(90, config('coloringbook.token.ttl_days'));
    }
}
