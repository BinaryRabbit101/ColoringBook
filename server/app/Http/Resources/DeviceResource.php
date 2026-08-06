<?php

namespace App\Http\Resources;

use App\Models\Device;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * `is_signed_in` is only present when the caller went through
 * `DeviceTokens::devicesFor()`, which is the only place that knows whether a
 * live token still exists for the device.
 *
 * @mixin Device
 */
class DeviceResource extends JsonResource
{
    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        return [
            'ulid' => $this->ulid,
            'device_uid' => $this->device_uid,
            'device_name' => $this->device_name,
            'platform' => $this->platform,
            'last_seen_at' => $this->last_seen_at?->toIso8601String(),
            'created_at' => $this->created_at?->toIso8601String(),
            'is_signed_in' => (bool) ($this->resource->getAttribute('is_signed_in') ?? false),
        ];
    }
}
