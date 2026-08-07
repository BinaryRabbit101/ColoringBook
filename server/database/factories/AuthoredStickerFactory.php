<?php

namespace Database\Factories;

use App\Models\Asset;
use App\Models\AuthoredSticker;
use App\Models\AuthoredStickerSet;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Str;

/**
 * @extends Factory<AuthoredSticker>
 */
class AuthoredStickerFactory extends Factory
{
    /**
     * A sticker with a clean verdict — the only shape that can be published.
     *
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        return [
            'authored_sticker_set_id' => AuthoredStickerSet::factory(),
            'sticker_index' => 0,
            'sticker_id' => Str::slug(fake()->unique()->word()),
            'title' => null,
            'image_asset_id' => Asset::factory()->kind('sticker'),
            'image_w' => 256,
            'image_h' => 256,
            'validation_errors' => [],
            'validation_warnings' => [],
        ];
    }

    /**
     * A sticker whose image `StickerValidation` refused — what a publish has to
     * refuse over.
     */
    public function invalid(string $reason = 'this is not an image any browser or the game could open.'): static
    {
        return $this->state(fn (array $attributes): array => [
            'validation_errors' => [$reason],
        ]);
    }
}
