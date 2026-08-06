<?php

namespace Database\Factories;

use App\Models\Asset;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Str;

/**
 * @extends Factory<Asset>
 */
class AssetFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        $sha256 = hash('sha256', Str::random(32));

        return [
            'kind' => 'display',
            'storage_path' => Asset::pathFor($sha256),
            'bytes' => fake()->numberBetween(1_000, 900_000),
            'sha256' => $sha256,
            'mime' => 'image/png',
            'width' => 2048,
            'height' => 2048,
        ];
    }

    public function kind(string $kind): static
    {
        return $this->state(fn (array $attributes) => ['kind' => $kind]);
    }

    /**
     * The regions JSON beside a page's art — not an image, so no dimensions.
     */
    public function regions(): static
    {
        return $this->state(fn (array $attributes) => [
            'kind' => 'regions',
            'mime' => 'application/json',
            'width' => null,
            'height' => null,
        ]);
    }
}
