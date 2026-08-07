<?php

namespace Database\Factories;

use App\Models\Asset;
use App\Models\Sticker;
use App\Models\StickerSet;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Str;

/**
 * @extends Factory<Sticker>
 */
class StickerFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        return [
            'sticker_set_id' => StickerSet::factory(),
            'sticker_index' => 0,
            'sticker_id' => Str::slug(fake()->unique()->word()),
            'title' => fake()->word(),
            'image_asset_id' => Asset::factory()->kind('sticker'),
            'image_w' => 256,
            'image_h' => 256,
        ];
    }
}
