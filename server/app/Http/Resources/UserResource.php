<?php

namespace App\Http\Resources;

use App\Models\User;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * The parent, as the game sees them: a ULID and an email. That really is the
 * whole account (DLC_SERVER.md §4.1). The numeric key never crosses the
 * boundary.
 *
 * @mixin User
 */
class UserResource extends JsonResource
{
    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        return [
            'ulid' => $this->ulid,
            'email' => $this->email,
            'created_at' => $this->created_at?->toIso8601String(),
        ];
    }
}
