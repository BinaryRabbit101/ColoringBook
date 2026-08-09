<?php

namespace Tests\Feature\Api;

use App\Exceptions\ApiException;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Route;
use RuntimeException;
use Tests\TestCase;

/**
 * The house error shape, rendered centrally in bootstrap/app.php.
 *
 *     {"error": {"code": "SNAKE_CASE", "message": "…"}}
 *
 * Every work package inherits this; the game client branches on `code` and
 * never on the prose (DLC_SERVER.md §11).
 */
class ApiErrorShapeTest extends TestCase
{
    use RefreshDatabase;

    public function test_an_unknown_api_route_is_not_found(): void
    {
        $this->getJson('/api/v1/nope')
            ->assertNotFound()
            ->assertExactJson([
                'error' => [
                    'code' => 'NOT_FOUND',
                    'message' => 'The requested resource does not exist.',
                ],
            ]);
    }

    public function test_a_missing_token_is_unauthenticated(): void
    {
        $this->getJson('/api/v1/entitlements')
            ->assertUnauthorized()
            ->assertJsonPath('error.code', 'UNAUTHENTICATED')
            ->assertJsonMissingPath('error.details');
    }

    public function test_a_bad_method_is_method_not_allowed(): void
    {
        $this->putJson('/api/v1/device/register')
            ->assertStatus(405)
            ->assertJsonPath('error.code', 'METHOD_NOT_ALLOWED');
    }

    public function test_validation_failures_carry_a_details_map(): void
    {
        $response = $this->postJson('/api/v1/device/register', [
            'device_uid' => 'short',
        ]);

        $response->assertStatus(422)
            ->assertJsonPath('error.code', 'VALIDATION_FAILED')
            ->assertJsonPath(
                'error.details.device_uid.0',
                'The device uid field must be at least 8 characters.',
            );

        // The Laravel default shape must not leak through alongside ours.
        $response->assertJsonMissingPath('errors')
            ->assertJsonMissingPath('message');
    }

    public function test_a_model_that_does_not_exist_is_not_found(): void
    {
        $this->getJson('/api/v1/packs/no-such-pack')
            ->assertNotFound()
            ->assertJsonPath('error.code', 'NOT_FOUND');
    }

    public function test_a_deliberate_api_exception_keeps_its_code_and_details(): void
    {
        Route::middleware('api')->get('api/v1/_test_api_exception', function (): never {
            throw new ApiException(
                'ENTITLEMENT_REQUIRED',
                'You do not own that pack.',
                403,
                ['pack_slug' => 'coyote-2026'],
            );
        });

        $this->getJson('/api/v1/_test_api_exception')
            ->assertForbidden()
            ->assertExactJson([
                'error' => [
                    'code' => 'ENTITLEMENT_REQUIRED',
                    'message' => 'You do not own that pack.',
                    'details' => ['pack_slug' => 'coyote-2026'],
                ],
            ]);
    }

    public function test_an_unexpected_failure_is_a_generic_server_error(): void
    {
        config(['app.debug' => false]);

        Route::middleware('api')->get('api/v1/_test_boom', function (): never {
            throw new RuntimeException('a stack trace the client must never see');
        });

        $this->getJson('/api/v1/_test_boom')
            ->assertStatus(500)
            ->assertExactJson([
                'error' => [
                    'code' => 'SERVER_ERROR',
                    'message' => 'Something went wrong. Please try again.',
                ],
            ]);
    }

    public function test_throttled_requests_report_a_throttled_code_with_retry_after(): void
    {
        for ($i = 0; $i < 6; $i++) {
            $this->postJson('/api/v1/device/register', []);
        }

        $this->postJson('/api/v1/device/register', [])
            ->assertStatus(429)
            ->assertJsonPath('error.code', 'THROTTLED')
            ->assertHeader('Retry-After');
    }

    public function test_web_routes_are_left_alone(): void
    {
        $user = User::factory()->create();

        // The same "no such row" that would be NOT_FOUND under /api, on a
        // dashboard route: the renderer must not touch it.
        $response = $this->actingAs($user->fill(['is_admin' => true]))
            ->get('/admin/packs/no-such-pack');

        $response->assertNotFound();

        // Not JSON at all: the dashboard still gets Laravel's own error page.
        $this->assertStringNotContainsString(
            'application/json',
            (string) $response->headers->get('Content-Type'),
        );
    }
}
