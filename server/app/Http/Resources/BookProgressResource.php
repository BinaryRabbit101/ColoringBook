<?php

namespace App\Http\Resources;

use App\Models\BookProgress;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * One book's progress on the wire — DLC_SERVER.md §11 "Sync".
 *
 * The same shape is used three times over: the elements of `GET`'s `books`,
 * and the `server` block carried by a per-book conflict in `PUT`'s results.
 * Keeping it in one place is what stops those two drifting apart.
 *
 * @mixin BookProgress
 */
class BookProgressResource extends JsonResource
{
    /**
     * @return array<string, mixed>
     */
    public function toArray(Request $request): array
    {
        return [
            'book_uid' => $this->book_uid,
            'revision' => $this->revision,
            'current_page_index' => $this->current_page_index,
            'page_statuses' => $this->pageStatuses(),
            'furthest_page_index' => $this->furthest_page_index,
            'client_updated_at' => $this->client_updated_at->toIso8601String(),
            // BL-18. Index-parallel to `page_statuses`, null where the page
            // has never been reset, trailing nulls trimmed — so a book nobody
            // has pressed "Start over" in sends `[]` and costs nothing.
            'page_erased_at' => BookProgress::encodeErasures($this->pageErasures()) ?? [],
        ];
    }
}
