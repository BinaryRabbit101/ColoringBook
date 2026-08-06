<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Attributes\Guarded;
use Illuminate\Database\Eloquent\Attributes\Table;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;

/**
 * The current picture on one page — DLC_SERVER.md §5 "Saves", §6.3.
 *
 * Paint cannot be merged: compositing two devices' layers produces something
 * neither child drew. So this row is decided by last-write-wins on
 * `client_painted_at`, and the version it displaced is kept for 30 days in
 * `retained_paint_layers` rather than deleted.
 *
 * `revision` is not optimistic concurrency the way `book_progress.revision`
 * is — nothing sends a `base_revision` for paint. It is a monotonic counter
 * that (a) tells a client whether the server moved, and (b) names the retained
 * file of the version this one replaced (`page_NN.<revision>.png`).
 *
 * @property int $id
 * @property string $ulid
 * @property int $book_progress_id
 * @property int $page_index
 * @property string $sha256
 * @property int $bytes
 * @property string $storage_path
 * @property int $revision
 * @property CarbonImmutable $client_painted_at
 * @property Carbon|null $created_at
 * @property Carbon|null $updated_at
 * @property-read BookProgress $bookProgress
 * @property-read Collection<int, RetainedPaintLayer> $retainedVersions
 */
#[Table('paint_layers')]
#[Guarded(['*'])]
class PaintLayer extends Model
{
    /**
     * Microsecond precision, matching `timestamp(6)` in the migration.
     *
     * `client_painted_at` is the entire LWW comparison, and two save points a
     * few hundred milliseconds apart (page complete, then leaving the book)
     * are perfectly ordinary. At whole-second resolution those two writes tie,
     * and a tie is resolved by arrival order — which is exactly the ordering
     * a flaky connection can reverse.
     *
     * @var string
     */
    protected $dateFormat = self::DATE_FORMAT;

    /**
     * The storage format for every timestamp on this table. Public for the
     * same reason `BookProgress::DATE_FORMAT` is: a `where(...)` binding has to
     * be formatted by hand or the grammar truncates the microseconds off.
     */
    public const DATE_FORMAT = 'Y-m-d H:i:s.u';

    /**
     * The signed blob URL addresses this row, never its numeric key.
     */
    public function getRouteKeyName(): string
    {
        return 'ulid';
    }

    /**
     * @return BelongsTo<BookProgress, $this>
     */
    public function bookProgress(): BelongsTo
    {
        return $this->belongsTo(BookProgress::class);
    }

    /**
     * Older versions of this page, newest loss first.
     *
     * @return HasMany<RetainedPaintLayer, $this>
     */
    public function retainedVersions(): HasMany
    {
        return $this->hasMany(RetainedPaintLayer::class)->orderByDesc('retained_at');
    }

    protected static function booted(): void
    {
        static::creating(function (PaintLayer $layer): void {
            if (blank($layer->ulid)) {
                $layer->ulid = (string) Str::ulid();
            }
        });
    }

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'page_index' => 'integer',
            'bytes' => 'integer',
            'revision' => 'integer',
            'client_painted_at' => 'immutable_datetime',
        ];
    }
}
