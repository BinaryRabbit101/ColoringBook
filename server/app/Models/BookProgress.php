<?php

namespace App\Models;

use App\Services\ProgressMerge;
use App\Services\ProgressState;
use Carbon\CarbonImmutable;
use Database\Factories\BookProgressFactory;
use Illuminate\Database\Eloquent\Attributes\Guarded;
use Illuminate\Database\Eloquent\Attributes\Scope;
use Illuminate\Database\Eloquent\Attributes\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Carbon;

/**
 * One book's worth of a child's progress — DLC_SERVER.md §5 "Saves", §6.
 *
 * A near-CRDT by construction: page statuses only ever climb
 * (untouched → in_progress → complete) and `furthest_page_index` is monotonic,
 * which is what lets `ProgressMerge` resolve two devices without ever asking a
 * five year old to pick a side (§6.3).
 *
 * `child_profile_id` is nullable: an account that never created a profile
 * still has a shelf. Both foreign keys cascade — deleting the account or the
 * child really deletes the colouring (§4.1).
 *
 * @property int $id
 * @property int $user_id
 * @property int|null $child_profile_id
 * @property string $book_uid
 * @property int $revision
 * @property int $current_page_index
 * @property array<int, mixed> $page_statuses
 * @property array<int, mixed>|null $page_erased_at
 * @property int $furthest_page_index
 * @property CarbonImmutable $client_updated_at
 * @property Carbon|null $created_at
 * @property Carbon|null $updated_at
 * @property-read User $user
 * @property-read ChildProfile|null $childProfile
 * @property-read Collection<int, PaintLayer> $paintLayers
 */
#[Table('book_progress')]
#[Guarded(['*'])]
class BookProgress extends Model
{
    /** @use HasFactory<BookProgressFactory> */
    use HasFactory;

    /**
     * Microsecond precision, matching `timestamps(6)` in the migration: the
     * `since` cursor of `GET /sync/progress` is an `updated_at` comparison,
     * and whole seconds would hide a row written later in the same second as
     * the cursor the client was handed.
     *
     * @var string
     */
    protected $dateFormat = self::DATE_FORMAT;

    /**
     * The storage format for every timestamp on this table. Public because a
     * `where('updated_at', '>', …)` binding has to be formatted the same way —
     * the query grammar's own default would truncate the microseconds off.
     */
    public const DATE_FORMAT = 'Y-m-d H:i:s.u';

    /**
     * @return BelongsTo<User, $this>
     */
    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    /**
     * @return BelongsTo<ChildProfile, $this>
     */
    public function childProfile(): BelongsTo
    {
        return $this->belongsTo(ChildProfile::class);
    }

    /**
     * The pictures painted in this book on this shelf (WP4, design §5).
     *
     * One row per painted page, cascading on delete — a shelf's progress and
     * its pixels live and die together.
     *
     * @return HasMany<PaintLayer, $this>
     */
    public function paintLayers(): HasMany
    {
        return $this->hasMany(PaintLayer::class);
    }

    /**
     * Scope to one child's shelf, or to the account-level shelf when there is
     * no profile. Spelled out rather than left to `where(…, null)` because the
     * null case has to become `is null`, not `= null`.
     *
     * @param  Builder<$this>  $query
     */
    #[Scope]
    protected function forProfile(Builder $query, ?ChildProfile $profile): void
    {
        $profile === null
            ? $query->whereNull('child_profile_id')
            : $query->where('child_profile_id', $profile->id);
    }

    /**
     * The stored progress, as the pure value the merge rule works on.
     */
    public function toState(): ProgressState
    {
        return new ProgressState(
            $this->current_page_index,
            $this->pageStatuses(),
            $this->furthest_page_index,
            CarbonImmutable::instance($this->client_updated_at),
            $this->pageErasures(),
        );
    }

    /**
     * Write a merged state back onto the row. Does not save.
     */
    public function applyState(ProgressState $state): static
    {
        $this->current_page_index = $state->currentPageIndex;
        $this->page_statuses = $state->pageStatuses;
        $this->furthest_page_index = $state->furthestPageIndex;
        $this->client_updated_at = $state->clientUpdatedAt;
        $this->page_erased_at = self::encodeErasures($state->pageErasedAt);

        return $this;
    }

    /**
     * The per-page "Start over" clocks (BL-18), index-parallel to
     * `page_statuses`, as instants.
     *
     * The column is JSON and nullable, so it can hold anything or nothing;
     * anything unparseable reads as null, which is "this page has never been
     * reset" and therefore the safe answer — a bogus clock would silently wipe
     * a page's status instead.
     *
     * @return list<CarbonImmutable|null>
     */
    public function pageErasures(): array
    {
        $raw = $this->page_erased_at;

        if (! is_array($raw)) {
            return [];
        }

        return ProgressState::trim(array_values(array_map(
            static function (mixed $at): ?CarbonImmutable {
                if (! is_string($at) || $at === '') {
                    return null;
                }

                try {
                    return CarbonImmutable::parse($at)->utc();
                } catch (\Throwable) {
                    return null;
                }
            },
            $raw,
        )));
    }

    /**
     * When "Start over" was last pressed on one page of this book, or null.
     */
    public function erasedPageAt(int $pageIndex): ?CarbonImmutable
    {
        return $this->pageErasures()[$pageIndex] ?? null;
    }

    /**
     * The inverse: instants as the microsecond ISO strings the column stores.
     * Null for a book nobody has reset, so the common row stays as small as it
     * was before BL-18.
     *
     * @param  list<CarbonImmutable|null>  $erasures
     * @return list<string|null>|null
     */
    public static function encodeErasures(array $erasures): ?array
    {
        $trimmed = ProgressState::trim($erasures);

        if ($trimmed === []) {
            return null;
        }

        return array_map(
            static fn (?CarbonImmutable $at): ?string => $at?->utc()->format('Y-m-d\TH:i:s.up'),
            $trimmed,
        );
    }

    /**
     * Record "Start over" on one page, keeping the clock monotonic. Does not
     * save. Returns true when the clock actually moved.
     */
    public function erasePage(int $pageIndex, CarbonImmutable $at): bool
    {
        $erasures = $this->pageErasures();
        $current = $erasures[$pageIndex] ?? null;

        if ($current !== null && $current->greaterThanOrEqualTo($at)) {
            return false;
        }

        for ($page = count($erasures); $page < $pageIndex; $page++) {
            $erasures[$page] = null;
        }

        $erasures[$pageIndex] = $at;
        // Re-keyed rather than assigned in place: writing past the end leaves
        // an array whose keys are a list only by luck, and `encodeErasures`
        // is defined over a list.
        $this->page_erased_at = self::encodeErasures(array_values($erasures));

        return true;
    }

    /**
     * The page statuses as a clean list of strings.
     *
     * The column is JSON, so it can in principle come back holding anything;
     * anything unrecognised reads as `untouched`, which is the identity of the
     * merge and therefore the only safe fallback.
     *
     * @return list<string>
     */
    public function pageStatuses(): array
    {
        return array_values(array_map(
            static fn (mixed $status): string => is_string($status) ? $status : ProgressMerge::UNTOUCHED,
            $this->page_statuses,
        ));
    }

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'page_statuses' => 'array',
            'page_erased_at' => 'array',
            'revision' => 'integer',
            'current_page_index' => 'integer',
            'furthest_page_index' => 'integer',
            'client_updated_at' => 'immutable_datetime',
        ];
    }
}
