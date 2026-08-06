<?php

namespace Database\Factories;

use App\Models\Pack;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Str;

/**
 * @extends Factory<Pack>
 */
class PackFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        $title = Str::title(fake()->unique()->word().' '.fake()->word());

        return [
            'slug' => Str::slug($title).'-'.fake()->unique()->numberBetween(1, 99_999),
            'title' => $title,
            'blurb' => fake()->sentence(),
            'cover_path' => 'cover.png',
            'status' => Pack::STATUS_PUBLISHED,
            'is_free' => false,
            'sort_order' => 0,
        ];
    }

    public function draft(): static
    {
        return $this->state(fn (array $attributes) => ['status' => Pack::STATUS_DRAFT]);
    }

    public function retired(): static
    {
        return $this->state(fn (array $attributes) => ['status' => Pack::STATUS_RETIRED]);
    }

    public function free(): static
    {
        return $this->state(fn (array $attributes) => ['is_free' => true]);
    }
}
