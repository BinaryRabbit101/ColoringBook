<?php

namespace Database\Factories;

use App\Models\ChildProfile;
use App\Models\User;
use Illuminate\Database\Eloquent\Factories\Factory;

/**
 * @extends Factory<ChildProfile>
 */
class ChildProfileFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        return [
            'user_id' => User::factory(),
            'nickname' => fake()->firstName(),
            'avatar_index' => fake()->numberBetween(0, (int) config('coloringbook.profiles.avatar_count') - 1),
            'default_mode' => 'child',
        ];
    }

    /**
     * A profile that opens in the grown-up palette.
     */
    public function adultMode(): static
    {
        return $this->state(fn (array $attributes) => [
            'default_mode' => 'adult',
        ]);
    }
}
