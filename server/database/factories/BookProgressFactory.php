<?php

namespace Database\Factories;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\User;
use App\Services\ProgressMerge;
use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Factories\Factory;

/**
 * @extends Factory<BookProgress>
 */
class BookProgressFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        return [
            'user_id' => User::factory(),
            // Account-level by default: the shelf of an account that never
            // made a child profile is the common case, not the exception.
            'child_profile_id' => null,
            'book_uid' => fake()->unique()->slug(2).'-2026',
            'revision' => 1,
            'current_page_index' => 0,
            'page_statuses' => [ProgressMerge::UNTOUCHED, ProgressMerge::UNTOUCHED],
            'furthest_page_index' => 0,
            'client_updated_at' => CarbonImmutable::now(),
        ];
    }

    /**
     * Belonging to one child rather than the account as a whole.
     */
    public function forProfile(ChildProfile $profile): static
    {
        return $this->state(fn (array $attributes): array => [
            'user_id' => $profile->user_id,
            'child_profile_id' => $profile->id,
        ]);
    }
}
