<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Database\Factories\AuthoredPageFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Str;

/**
 * One page of an authored book: what the operator uploaded, plus whatever the
 * mapping job has made of it so far (BL-24, §10.3).
 *
 * The two halves are separate on purpose. `display_asset_id` / `mask_asset_id`
 * are uploads and change only when a human replaces them; everything from
 * `idmap_asset_id` down is **derived** and is thrown away and recomputed
 * whenever an upload or a tuning knob moves. That is why the derived columns
 * are nullable rather than defaulted: a page between an upload and its mapping
 * job has no ID map, and pretending otherwise is how a half-mapped page gets
 * published.
 *
 * `mapping_status` says whether the pipeline ran; `validation_errors` says
 * whether §10.1 liked the result. They are independent, and both must be clean
 * before the book can publish: a page can map perfectly and still be
 * unpublishable because one region swallowed the drawing — which is a gap in
 * the line art, and only the artist can fix it.
 *
 * @property int $id
 * @property string $ulid
 * @property int $authored_book_id
 * @property int $page_index
 * @property string|null $title
 * @property int $display_asset_id
 * @property int|null $mask_asset_id
 * @property int|null $idmap_asset_id
 * @property int|null $regions_asset_id
 * @property int|null $mask_artifact_asset_id
 * @property int|null $image_w
 * @property int|null $image_h
 * @property int|null $region_count
 * @property string $mapping_status
 * @property string|null $mapping_error
 * @property string|null $mapping_log
 * @property CarbonImmutable|null $mapped_at
 * @property list<string>|null $validation_errors
 * @property list<string>|null $validation_warnings
 * @property array<string, float|int>|null $tuning
 * @property CarbonImmutable|null $created_at
 * @property CarbonImmutable|null $updated_at
 * @property-read AuthoredBook $book
 * @property-read Asset $displayAsset
 * @property-read Asset|null $maskAsset
 * @property-read Asset|null $idmapAsset
 * @property-read Asset|null $regionsAsset
 * @property-read Asset|null $maskArtifactAsset
 */
#[Fillable(['page_index', 'title', 'display_asset_id', 'mask_asset_id', 'tuning'])]
class AuthoredPage extends Model
{
    /** @use HasFactory<AuthoredPageFactory> */
    use HasFactory;

    /** Uploaded, nothing queued yet. */
    public const STATUS_PENDING = 'pending';

    /** A mapping job is on the queue for this page. */
    public const STATUS_QUEUED = 'queued';

    /** Headless Godot is running right now. */
    public const STATUS_RUNNING = 'running';

    /** Artifacts exist. Says nothing about whether they *validate*. */
    public const STATUS_MAPPED = 'mapped';

    /** The pipeline refused, or there is no engine on this box. */
    public const STATUS_FAILED = 'failed';

    public const STATUSES = [
        self::STATUS_PENDING,
        self::STATUS_QUEUED,
        self::STATUS_RUNNING,
        self::STATUS_MAPPED,
        self::STATUS_FAILED,
    ];

    /**
     * The tuning knobs a page may override, and the flag each becomes on the
     * pipeline's command line. The names are the pipeline's own, minus the
     * leading dashes — one vocabulary between the web form, the row and the
     * dev-box run, so a page mapped in the browser can be reproduced by hand.
     *
     * @var array<string, string>
     */
    public const TUNING_FLAGS = [
        'line_alpha_min' => '--line-alpha-min',
        'line_luminance_max' => '--line-luminance-max',
        'dilate' => '--dilate',
        'min_area' => '--min-area',
        'rdp' => '--rdp',
        'giant_fraction' => '--giant-fraction',
    ];

    public function getRouteKeyName(): string
    {
        return 'ulid';
    }

    /**
     * @return BelongsTo<AuthoredBook, $this>
     */
    public function book(): BelongsTo
    {
        return $this->belongsTo(AuthoredBook::class, 'authored_book_id');
    }

    /**
     * @return BelongsTo<Asset, $this>
     */
    public function displayAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'display_asset_id');
    }

    /**
     * @return BelongsTo<Asset, $this>
     */
    public function maskAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'mask_asset_id');
    }

    /**
     * @return BelongsTo<Asset, $this>
     */
    public function idmapAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'idmap_asset_id');
    }

    /**
     * @return BelongsTo<Asset, $this>
     */
    public function regionsAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'regions_asset_id');
    }

    /**
     * @return BelongsTo<Asset, $this>
     */
    public function maskArtifactAsset(): BelongsTo
    {
        return $this->belongsTo(Asset::class, 'mask_artifact_asset_id');
    }

    /**
     * `page_01` for index 0. The API speaks 0-based indices everywhere and the
     * *files* are 1-based, matching what the client writes under
     * `user://paint/<slug>/` — one conversion, in one place.
     */
    public function fileStem(): string
    {
        return sprintf('page_%02d', $this->page_index + 1);
    }

    public function hasMask(): bool
    {
        return $this->mask_asset_id !== null;
    }

    public function isMapped(): bool
    {
        return $this->mapping_status === self::STATUS_MAPPED
            && $this->idmap_asset_id !== null
            && $this->regions_asset_id !== null;
    }

    /**
     * The §10.1 verdict as one boolean: mapped *and* the checks came back
     * clean. Warnings do not block — they are "worth a look", not "wrong".
     */
    public function isPublishable(): bool
    {
        return $this->isMapped() && ($this->validation_errors ?? []) === [];
    }

    /**
     * Why this page is not publishable, phrased for the operator rather than
     * for a log (§10.3: "a giant region still means 'a line has a gap — fix the
     * art'; the editor says so instead of hiding it").
     *
     * @return list<string>
     */
    public function publishBlockers(): array
    {
        $label = $this->label();

        if ($this->mapping_status === self::STATUS_FAILED) {
            return [sprintf(
                '%s: mapping failed — %s',
                $label,
                $this->mapping_error !== null && trim($this->mapping_error) !== ''
                    ? trim($this->mapping_error)
                    : __('the pipeline gave no reason.'),
            )];
        }

        if (! $this->isMapped()) {
            return [sprintf('%s: %s', $label, __('not mapped yet — wait for the mapping job to finish.'))];
        }

        return array_map(
            fn (string $error): string => sprintf('%s: %s', $label, $error),
            $this->validation_errors ?? [],
        );
    }

    /**
     * How this page is named in a message: its title when it has one, its
     * position when it does not.
     */
    public function label(): string
    {
        return $this->title !== null && trim($this->title) !== ''
            ? sprintf('Page %d (%s)', $this->page_index + 1, trim($this->title))
            : sprintf('Page %d', $this->page_index + 1);
    }

    /**
     * The tuning actually used for a run: the configured defaults with this
     * page's overrides on top.
     *
     * @return array<string, float|int>
     */
    public function effectiveTuning(): array
    {
        /** @var array<string, float|int> $defaults */
        $defaults = config('coloringbook.authoring.tuning', []);

        return [...$defaults, ...($this->tuning ?? [])];
    }

    protected static function booted(): void
    {
        static::creating(function (AuthoredPage $page): void {
            if (blank($page->ulid)) {
                $page->ulid = (string) Str::ulid();
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
            'image_w' => 'integer',
            'image_h' => 'integer',
            'region_count' => 'integer',
            'mapped_at' => 'immutable_datetime',
            'validation_errors' => 'array',
            'validation_warnings' => 'array',
            'tuning' => 'array',
        ];
    }
}
