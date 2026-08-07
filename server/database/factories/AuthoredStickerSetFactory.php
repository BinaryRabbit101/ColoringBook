<?php

namespace Database\Factories;

use App\Models\AuthoredStickerSet;
use App\Models\Pack;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Str;

/**
 * @extends Factory<AuthoredStickerSet>
 */
class AuthoredStickerSetFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        $title = Str::title(fake()->unique()->word());
        $uid = Str::slug($title).'-stickers-'.fake()->unique()->numberBetween(1, 99_999);

        return [
            // Slug = uid, kind = sticker_set: the one-set pack a web-authored
            // set publishes into (BL-37).
            'pack_id' => Pack::factory()->state([
                'slug' => $uid,
                'kind' => Pack::KIND_STICKER_SET,
                'title' => $title,
                // A set created here has published nothing yet.
                'status' => Pack::STATUS_DRAFT,
            ]),
            'set_uid' => $uid,
            'title' => $title,
            'blurb' => null,
            'sort_order' => 100,
        ];
    }
}
