<?php

namespace Database\Factories;

use App\Models\Asset;
use App\Models\AuthoredBook;
use App\Models\AuthoredPage;
use Illuminate\Database\Eloquent\Factories\Factory;

/**
 * @extends Factory<AuthoredPage>
 */
class AuthoredPageFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        return [
            'authored_book_id' => AuthoredBook::factory(),
            'page_index' => 0,
            'title' => null,
            'display_asset_id' => Asset::factory()->kind('display'),
            'mask_asset_id' => null,
            'mapping_status' => AuthoredPage::STATUS_PENDING,
        ];
    }

    /**
     * A page the pipeline has already been through, with a clean §10.1 verdict
     * — the only shape that can be published.
     */
    public function mapped(): static
    {
        return $this->state(fn (array $attributes): array => [
            'idmap_asset_id' => Asset::factory()->kind('idmap'),
            'regions_asset_id' => Asset::factory()->regions(),
            'image_w' => 16,
            'image_h' => 16,
            'region_count' => 4,
            'mapping_status' => AuthoredPage::STATUS_MAPPED,
            'validation_errors' => [],
            'validation_warnings' => [],
            'mapped_at' => now(),
        ]);
    }
}
