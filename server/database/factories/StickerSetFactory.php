<?php

namespace Database\Factories;

use App\Models\Pack;
use App\Models\StickerSet;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Str;

/**
 * @extends Factory<StickerSet>
 */
class StickerSetFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        $title = Str::title(fake()->unique()->word());

        return [
            'pack_id' => Pack::factory()->state(['kind' => Pack::KIND_STICKER_SET]),
            // Authored, never derived — and unique across the whole catalog
            // because every saved sticker placement names it (BL-36/§6.1).
            'set_uid' => Str::slug($title).'-stickers-'.fake()->unique()->numberBetween(1, 99_999),
            'title' => $title,
            'cover_asset_id' => null,
            'sort_order' => 100,
        ];
    }
}
