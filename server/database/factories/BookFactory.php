<?php

namespace Database\Factories;

use App\Models\Book;
use App\Models\Pack;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Str;

/**
 * @extends Factory<Book>
 */
class BookFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        $title = Str::title(fake()->unique()->word());

        return [
            'pack_id' => Pack::factory(),
            // Authored, never derived — and unique across the whole catalog
            // because every save row keys off it (DLC_SERVER.md §6.1).
            'book_uid' => Str::slug($title).'-'.fake()->unique()->numberBetween(1, 99_999),
            'title' => $title,
            'cover_asset_id' => null,
            'sort_order' => 0,
        ];
    }
}
