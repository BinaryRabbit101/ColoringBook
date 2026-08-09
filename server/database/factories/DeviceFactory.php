<?php

namespace Database\Factories;

use App\Models\Device;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Str;

/**
 * @extends Factory<Device>
 */
class DeviceFactory extends Factory
{
    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        return [
            // The client mints a ULID and keeps it in user:// forever.
            'device_uid' => (string) Str::ulid(),
            'device_name' => fake()->firstName()."'s tablet",
            'platform' => fake()->randomElement(['android', 'web', 'windows']),
            'last_seen_at' => now(),
        ];
    }

    /**
     * A device that has never phoned home since it was created.
     */
    public function neverSeen(): static
    {
        return $this->state(fn (array $attributes) => [
            'last_seen_at' => null,
        ]);
    }
}
