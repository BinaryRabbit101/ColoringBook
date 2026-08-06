<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Attributes\Guarded;
use Illuminate\Database\Eloquent\Attributes\Scope;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;

/**
 * A picture that lost a last-write-wins race, kept for 30 days (§6.3).
 *
 * The file it points at is `page_NN.<revision>.png` beside the live
 * `page_NN.png`. Two things read this table: the parent dashboard, which
 * offers "restore the older picture", and `paint:prune`, which deletes rows
 * (and blobs) whose `retained_at` is older than the retention window.
 *
 * @property int $id
 * @property string $ulid
 * @property int $paint_layer_id
 * @property string $sha256
 * @property int $bytes
 * @property string $storage_path
 * @property int $revision
 * @property CarbonImmutable $client_painted_at
 * @property CarbonImmutable $retained_at
 * @property Carbon|null $created_at
 * @property Carbon|null $updated_at
 * @property-read PaintLayer $paintLayer
 */
#[Guarded(['*'])]
class RetainedPaintLayer extends Model
{
    /**
     * @var string
     */
    protected $dateFormat = PaintLayer::DATE_FORMAT;

    public function getRouteKeyName(): string
    {
        return 'ulid';
    }

    /**
     * @return BelongsTo<PaintLayer, $this>
     */
    public function paintLayer(): BelongsTo
    {
        return $this->belongsTo(PaintLayer::class);
    }

    /**
     * Everything whose 30-day lease has run out.
     *
     * Formatted by hand: this column is microsecond precision, and the query
     * grammar's default would drop them (see PaintLayer::DATE_FORMAT).
     *
     * @param  Builder<$this>  $query
     */
    #[Scope]
    protected function expired(Builder $query, CarbonImmutable $before): void
    {
        $query->where('retained_at', '<', $before->format(PaintLayer::DATE_FORMAT));
    }

    protected static function booted(): void
    {
        static::creating(function (RetainedPaintLayer $retained): void {
            if (blank($retained->ulid)) {
                $retained->ulid = (string) Str::ulid();
            }
        });
    }

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'bytes' => 'integer',
            'revision' => 'integer',
            'client_painted_at' => 'immutable_datetime',
            'retained_at' => 'immutable_datetime',
        ];
    }
}
