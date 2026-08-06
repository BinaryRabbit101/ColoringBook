<?php

namespace Database\Factories;

use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\User;
use Illuminate\Database\Eloquent\Factories\Factory;

/**
 * @extends Factory<Entitlement>
 */
class EntitlementFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        return [
            'user_id' => User::factory(),
            'pack_id' => Pack::factory(),
            'source' => Entitlement::SOURCE_PROMO,
            'platform' => null,
            'platform_txn_id' => null,
            'granted_at' => now(),
            'revoked_at' => null,
        ];
    }

    public function source(string $source): static
    {
        return $this->state(fn (array $attributes) => ['source' => $source]);
    }

    /**
     * A refunded or admin-revoked claim: the row survives, the access doesn't.
     */
    public function revoked(): static
    {
        return $this->state(fn (array $attributes) => ['revoked_at' => now()]);
    }
}
