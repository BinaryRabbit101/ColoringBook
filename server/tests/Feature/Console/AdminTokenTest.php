<?php

namespace Tests\Feature\Console;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Sanctum\PersonalAccessToken;
use Tests\TestCase;

/**
 * `php artisan admin:token` — the only mint for a token that can publish.
 *
 * There is deliberately no endpoint and no UI button for this: issuing it
 * should require a shell on the server, not a session someone walked away
 * from.
 */
class AdminTokenTest extends TestCase
{
    use RefreshDatabase;

    public function test_it_mints_a_token_with_only_the_admin_ability(): void
    {
        $user = User::factory()->admin()->create(['email' => 'ops@example.com']);

        $this->artisan('admin:token', ['email' => 'ops@example.com'])->assertSuccessful();

        /** @var PersonalAccessToken $token */
        $token = PersonalAccessToken::query()->sole();

        $this->assertSame($user->id, $token->tokenable_id);
        $this->assertSame(['admin'], $token->abilities);
        $this->assertSame('pack-build', $token->name);
        $this->assertNotNull($token->expires_at);
    }

    public function test_it_refuses_an_account_that_is_not_an_admin(): void
    {
        User::factory()->create(['email' => 'parent@example.com']);

        $this->artisan('admin:token', ['email' => 'parent@example.com'])->assertFailed();

        $this->assertSame(0, PersonalAccessToken::query()->count());
    }

    public function test_it_refuses_an_unknown_email(): void
    {
        $this->artisan('admin:token', ['email' => 'nobody@example.com'])->assertFailed();
    }

    public function test_days_zero_means_no_expiry(): void
    {
        User::factory()->admin()->create(['email' => 'ops@example.com']);

        $this->artisan('admin:token', ['email' => 'ops@example.com', '--days' => 0])
            ->assertSuccessful();

        $this->assertNull(PersonalAccessToken::query()->sole()->expires_at);
    }
}
