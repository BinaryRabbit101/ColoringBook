<?php

namespace Database\Factories;

use App\Models\Pack;
use App\Models\PackVersion;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Str;

/**
 * @extends Factory<PackVersion>
 */
class PackVersionFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        $version = 1;

        return [
            'pack_id' => Pack::factory(),
            'version' => $version,
            'manifest' => [
                'manifest_version' => 1,
                'pack_version' => $version,
                'books' => [],
                'files' => [],
            ],
            'archive_path' => 'pack/v1/pack.zip',
            'archive_bytes' => fake()->numberBetween(1_000, 8_000_000),
            'archive_sha256' => hash('sha256', Str::random(32)),
            'min_client_version' => '0.1.0',
            'published_at' => now(),
        ];
    }

    public function draft(): static
    {
        return $this->state(fn (array $attributes) => ['published_at' => null]);
    }

    public function version(int $version): static
    {
        return $this->state(fn (array $attributes) => [
            'version' => $version,
            'manifest' => array_merge(
                is_array($attributes['manifest'] ?? null) ? $attributes['manifest'] : [],
                ['pack_version' => $version],
            ),
        ]);
    }

    public function requiresClient(string $minClientVersion): static
    {
        return $this->state(fn (array $attributes) => [
            'min_client_version' => $minClientVersion,
        ]);
    }
}
