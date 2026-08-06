<?php

namespace App\Http\Resources;

use App\Models\Pack;
use App\Models\PackVersion;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * A pack on the admin's shelf — every status, drafts included, which is the
 * one thing that separates it from `PackResource`.
 *
 * @mixin Pack
 */
class AdminPackResource extends JsonResource
{
    public function __construct(Pack $pack, private readonly bool $withVersions = false)
    {
        parent::__construct($pack);
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        $versions = $this->versions;
        $published = null;

        foreach ($versions as $version) {
            /** @var PackVersion $version */
            if ($version->published_at !== null && ($published === null || $version->version > $published)) {
                $published = $version->version;
            }
        }

        $payload = [
            'slug' => $this->slug,
            'title' => $this->title,
            'blurb' => $this->blurb,
            'status' => $this->status,
            'is_free' => $this->is_free,
            'sort_order' => $this->sort_order,
            'cover' => $this->cover_path,
            'cover_url' => $this->status === Pack::STATUS_PUBLISHED && $this->cover_path !== null
                ? route('api.v1.packs.cover', ['slug' => $this->slug])
                : null,
            'version_count' => $versions->count(),
            'latest_published_version' => $published,
            'created_at' => $this->created_at?->toIso8601String(),
        ];

        if ($this->withVersions) {
            $payload['versions'] = AdminPackVersionResource::collection($this->versions)->toArray($request);
        }

        return $payload;
    }
}
