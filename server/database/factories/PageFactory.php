<?php

namespace Database\Factories;

use App\Models\Asset;
use App\Models\Book;
use App\Models\Page;
use Illuminate\Database\Eloquent\Factories\Factory;

/**
 * @extends Factory<Page>
 */
class PageFactory extends Factory
{
    /**
     * A page with no mask — the ordinary case: the mask is optional and never
     * ships (BL-9 / BL-12).
     *
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        return [
            'book_id' => Book::factory(),
            'page_index' => 0,
            'title' => fake()->sentence(3),
            'display_asset_id' => Asset::factory()->kind('display'),
            'mask_asset_id' => null,
            'idmap_asset_id' => Asset::factory()->kind('idmap'),
            'regions_asset_id' => Asset::factory()->regions(),
            'image_w' => 2048,
            'image_h' => 2048,
            'region_count' => 15,
        ];
    }

    /**
     * A page whose mapping came from a hand-drawn outline mask, which the
     * server keeps for regeneration but never ships (§7.2, §10.1).
     */
    public function withMask(): static
    {
        return $this->state(fn (array $attributes) => [
            'mask_asset_id' => Asset::factory()->kind('mask'),
        ]);
    }
}
