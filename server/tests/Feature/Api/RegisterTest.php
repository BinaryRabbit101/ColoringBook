<?php

namespace Tests\Feature\Api;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Str;
use Tests\TestCase;

/**
 * `POST /api/v1/auth/register` — DLC_SERVER.md §11.
 */
class RegisterTest extends TestCase
{
    use RefreshDatabase;

    public function test_a_guardian_can_register_with_an_email_and_a_password(): void
    {
        $response = $this->postJson('/api/v1/auth/register', [
            'email' => 'parent@example.com',
            'password' => 'a-good-password',
            'is_guardian' => true,
        ]);

        $response->assertCreated()
            ->assertJsonPath('user.email', 'parent@example.com')
            ->assertJsonStructure(['user' => ['ulid', 'email', 'created_at']]);

        $user = User::query()->where('email', 'parent@example.com')->firstOrFail();

        $this->assertTrue(Str::isUlid($user->ulid));
        $this->assertNotSame('a-good-password', $user->password);
        $this->assertFalse($user->is_admin);

        // The entire PII footprint: an email and a password (§4.1).
        $this->assertNull($user->name);
    }

    public function test_the_numeric_key_never_crosses_the_boundary(): void
    {
        $response = $this->postJson('/api/v1/auth/register', [
            'email' => 'parent@example.com',
            'password' => 'a-good-password',
            'is_guardian' => true,
        ]);

        $this->assertArrayNotHasKey('id', $response->json('user'));
        $this->assertArrayNotHasKey('password', $response->json('user'));
    }

    public function test_the_guardian_confirmation_is_required(): void
    {
        $this->postJson('/api/v1/auth/register', [
            'email' => 'parent@example.com',
            'password' => 'a-good-password',
        ])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED')
            ->assertJsonPath(
                'error.details.is_guardian.0',
                'Please confirm you are the parent or guardian.',
            );

        $this->assertDatabaseCount('users', 0);
    }

    public function test_the_guardian_confirmation_must_actually_be_true(): void
    {
        $this->postJson('/api/v1/auth/register', [
            'email' => 'parent@example.com',
            'password' => 'a-good-password',
            'is_guardian' => false,
        ])->assertStatus(422);

        $this->assertDatabaseCount('users', 0);
    }

    public function test_the_email_must_be_unique(): void
    {
        User::factory()->create(['email' => 'parent@example.com']);

        $this->postJson('/api/v1/auth/register', [
            'email' => 'parent@example.com',
            'password' => 'a-good-password',
            'is_guardian' => true,
        ])
            ->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED');

        $this->assertDatabaseCount('users', 1);
    }

    public function test_a_short_password_is_rejected(): void
    {
        $this->postJson('/api/v1/auth/register', [
            'email' => 'parent@example.com',
            'password' => 'short',
            'is_guardian' => true,
        ])->assertStatus(422);
    }

    public function test_registration_carries_both_throttles(): void
    {
        $middleware = Route::getRoutes()->getByName('api.v1.auth.register')?->gatherMiddleware() ?? [];

        $this->assertContains('throttle:60,1', $middleware);
        $this->assertContains('throttle:6,1', $middleware);
    }
}
