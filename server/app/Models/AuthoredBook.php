<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Database\Factories\AuthoredBookFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Str;

/**
 * A colouring book being authored in the browser (BL-24, DLC_SERVER.md §10.3).
 *
 * This is draft state, and it is a different thing from `Book`. `Book` is the
 * catalog's record of what the newest release contains and is rebuilt from the
 * manifest on every publish; `AuthoredBook` is the workspace the operator edits
 * between releases and the source the publish step builds a §7.2 pack directory
 * from. Editing an authored book changes nothing a player can see until the
 * publish button is pressed.
 *
 * It owns a **one-book pack** whose slug is the `book_uid`, because packs stay
 * the delivery and entitlement unit (§10.3) — the game client has no notion of
 * a book that is not inside a pack, and BL-24 deliberately did not give it one.
 *
 * @property int $id
 * @property string $ulid
 * @property string $book_uid
 * @property int $pack_id
 * @property string $title
 * @property string|null $blurb
 * @property int|null $cover_asset_id
 * @property CarbonImmutable|null $created_at
 * @property CarbonImmutable|null $updated_at
 * @property-read Pack $pack
 * @property-read Asset|null $coverAsset
 * @property-read Collection<int, AuthoredPage> $pages
 */
#[Fillable(['book_uid', 'title', 'blurb'])]
class AuthoredBook extends Model
{
    /** @use HasFactory<AuthoredBookFactory> */
    use HasFactory;

    /**
     * §11 addresses an authored book by its `book_uid`, never by ULID or key.
     */
    public function getRouteKeyName(): string
    {
        return 'book_uid';
    }

    /**
     * @return BelongsTo<Pack, $this>
     */
    public function pack(): BelongsTo
    {
        return $this->belongsTo(Pack::class);
    }

    /**
     * The artist's cover art (BL-38) — **optional**.
     *
     * When it is null the publisher falls back to page one's display image, as
     * it always did, so a book that never gets a cover publishes exactly the
     * pack it published before.
     *
     * @return BelongsTo<Asset, $this>
     */
    public function coverAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'cover_asset_id');
    }

    /**
     * @return HasMany<AuthoredPage, $this>
     */
    public function pages(): HasMany
    {
        return $this->hasMany(AuthoredPage::class)->orderBy('page_index');
    }

    /**
     * When this book was last touched in the workspace (BL-38).
     *
     * The book's own `updated_at` is not enough: replacing a page's art, adding
     * one, reordering the lot — none of those write to this row, and all of them
     * change what a publish would ship. So the answer is the newest timestamp
     * anywhere in the book, which is what "has anything changed since the last
     * release?" actually means.
     *
     * @param  Collection<int, AuthoredPage>|null  $pages  Pass an already loaded
     *                                                     page list to avoid a
     *                                                     second query.
     */
    public function lastModifiedAt(?Collection $pages = null): ?CarbonImmutable
    {
        $pages ??= $this->pages()->get();
        $latest = $this->updated_at;

        foreach ($pages as $page) {
            if ($page->updated_at !== null && ($latest === null || $page->updated_at->greaterThan($latest))) {
                $latest = $page->updated_at;
            }
        }

        return $latest;
    }

    /**
     * Every reason this book cannot be published right now, in the operator's
     * language — the list the publish button refuses with (§10.3).
     *
     * Returning *all* of them matters: a six-page book with three unmapped
     * pages should say so once, not three times across three round trips.
     *
     * @param  Collection<int, AuthoredPage>|null  $pages  Pass an already
     *                                                     loaded page list to
     *                                                     avoid a second query.
     * @return list<string>
     */
    public function publishBlockers(?Collection $pages = null): array
    {
        $pages ??= $this->pages()->get();

        if ($pages->isEmpty()) {
            return [__('This book has no pages yet — add one before publishing.')];
        }

        $blockers = [];

        foreach ($pages as $page) {
            foreach ($page->publishBlockers() as $blocker) {
                $blockers[] = $blocker;
            }
        }

        return $blockers;
    }

    protected static function booted(): void
    {
        static::creating(function (AuthoredBook $book): void {
            if (blank($book->ulid)) {
                $book->ulid = (string) Str::ulid();
            }
        });
    }
}
