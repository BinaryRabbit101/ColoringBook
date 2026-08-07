<?php

namespace Database\Factories;

use App\Models\AuthoredBook;
use App\Models\Pack;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Str;

/**
 * @extends Factory<AuthoredBook>
 */
class AuthoredBookFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        $title = Str::title(fake()->unique()->word());
        $uid = Str::slug($title).'-'.fake()->unique()->numberBetween(1, 99_999);

        return [
            // Slug = uid: the one-book pack a web-authored book publishes into
            // (§10.3).
            'pack_id' => Pack::factory()->state([
                'slug' => $uid,
                'title' => $title,
                // A book created here has published nothing yet.
                'status' => Pack::STATUS_DRAFT,
            ]),
            'book_uid' => $uid,
            'title' => $title,
            'blurb' => null,
        ];
    }
}
