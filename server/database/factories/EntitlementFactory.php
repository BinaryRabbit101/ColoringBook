<?php

namespace Database\Factories;

use App\Models\Device;
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
            // Exactly one owner (BL-52). An account by default, because that is
            // what almost every test means; `ownedByDevice()` swaps it for the
            // anonymous tier.
            'user_id' => User::factory(),
            'device_id' => null,
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
     * A claim owned by an **anonymous device** rather than an account (BL-52).
     * Clears `user_id` in the same breath: a row with two owners is not a state
     * the application can produce, so it must not be one a factory can either.
     */
    public function ownedByDevice(Device $device): static
    {
        return $this->state(fn (array $attributes) => [
            'user_id' => null,
            'device_id' => $device->id,
        ]);
    }

    /**
     * A refunded or admin-revoked claim: the row survives, the access doesn't.
     */
    public function revoked(): static
    {
        return $this->state(fn (array $attributes) => ['revoked_at' => now()]);
    }
}
