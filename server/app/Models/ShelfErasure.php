<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Attributes\Guarded;
use Illuminate\Database\Eloquent\Attributes\Scope;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Carbon;

/**
 * When one shelf was last wiped — BL-18, DLC_SERVER.md §6.3 "Erasure".
 *
 * The whole of "Erase all progress" against a synced account, in one column.
 * Progress rows and pictures are really deleted by the wipe; this row is what
 * stops a device that was asleep through it pushing them all back. The merge
 * reads it as a censor: any state stamped `client_updated_at` **at or before**
 * `erased_at` did not survive, and reads as the empty book.
 *
 * No row means the shelf has never been erased. That is deliberately not the
 * same as the epoch, which would be a claim about time rather than the absence
 * of one.
 *
 * @property int $id
 * @property int $user_id
 * @property int|null $child_profile_id
 * @property CarbonImmutable $erased_at
 * @property Carbon|null $created_at
 * @property Carbon|null $updated_at
 * @property-read User $user
 * @property-read ChildProfile|null $childProfile
 */
#[Guarded(['*'])]
class ShelfErasure extends Model
{
    /**
     * Microsecond precision. The censor is a `<=` comparison against
     * `client_updated_at`, so at whole-second resolution a save written 300 ms
     * *after* an erase would be wiped by it — and, worse, a save written 300 ms
     * *before* one would survive it on some devices and not others depending
     * on rounding.
     *
     * @var string
     */
    protected $dateFormat = self::DATE_FORMAT;

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
     * Scope to one child's shelf, or the account-level one. The same spelling
     * `BookProgress` uses, and for the same reason: the null case has to
     * become `is null`, not `= null`.
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
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'erased_at' => 'immutable_datetime',
        ];
    }
}
