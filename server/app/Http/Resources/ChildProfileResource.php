<?php

namespace App\Http\Resources;

use App\Models\ChildProfile;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * @mixin ChildProfile
 */
class ChildProfileResource extends JsonResource
{
    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        return [
            'ulid' => $this->ulid,
            'nickname' => $this->nickname,
            'avatar_index' => $this->avatar_index,
            'default_mode' => $this->default_mode,
            'created_at' => $this->created_at?->toIso8601String(),
            'updated_at' => $this->updated_at?->toIso8601String(),
        ];
    }
}
