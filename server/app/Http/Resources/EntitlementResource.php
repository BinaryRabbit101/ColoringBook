<?php

namespace App\Http\Resources;

use App\Models\Entitlement;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * One line of `GET /entitlements` — `{pack_slug, latest_version, source,
 * granted_at}` exactly as §11 writes it.
 *
 * This doubles as the client's update check: comparing `latest_version`
 * against the version it has installed is the whole "is there an update"
 * question, folded into a call the client already makes on launch (§7.3), so
 * no extra round trip.
 *
 * @mixin Entitlement
 */
class EntitlementResource extends JsonResource
{
    public function __construct(
        Entitlement $entitlement,
        private readonly ?int $latestVersion,
    ) {
        parent::__construct($entitlement);
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        return [
            'pack_slug' => $this->pack->slug,
            'latest_version' => $this->latestVersion,
            'source' => $this->source,
            'granted_at' => $this->granted_at->toIso8601String(),
        ];
    }
}
