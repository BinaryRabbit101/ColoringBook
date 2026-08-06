<?php

namespace App\Http\Resources;

use App\Models\PaintLayer;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * What the client needs to answer "does the server have a newer picture than
 * mine?" without downloading a megabyte to find out.
 *
 * Deliberately metadata only — the pixels come from the signed blob URL.
 *
 * @mixin PaintLayer
 */
class PaintLayerResource extends JsonResource
{
    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        /** @var PaintLayer $layer */
        $layer = $this->resource;

        return self::describe($layer);
    }

    /**
     * The same shape, without a request in hand — the `PAINT_STALE` error
     * carries it as `details.server`, and an exception has no request.
     *
     * @return array<string, mixed>
     */
    public static function describe(PaintLayer $layer): array
    {
        return [
            'page_index' => $layer->page_index,
            'sha256' => $layer->sha256,
            'bytes' => $layer->bytes,
            'revision' => $layer->revision,
            'client_painted_at' => $layer->client_painted_at->utc()->format('Y-m-d\TH:i:s.up'),
        ];
    }
}
