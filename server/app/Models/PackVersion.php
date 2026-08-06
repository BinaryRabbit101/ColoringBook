<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Database\Factories\PackVersionFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * One immutable release of a pack (DLC_SERVER.md §7.3).
 *
 * Nothing in this application updates a published row: republishing a pack
 * writes the next integer. That is what makes the client's "installed version
 * per pack" check a plain integer comparison.
 *
 * @property int $id
 * @property int $pack_id
 * @property int $version
 * @property array<string, mixed> $manifest
 * @property string $archive_path
 * @property int $archive_bytes
 * @property string $archive_sha256
 * @property string|null $min_client_version
 * @property CarbonImmutable|null $published_at
 * @property CarbonImmutable|null $created_at
 * @property CarbonImmutable|null $updated_at
 * @property-read Pack $pack
 */
#[Fillable([
    'version',
    'manifest',
    'archive_path',
    'archive_bytes',
    'archive_sha256',
    'min_client_version',
    'published_at',
])]
class PackVersion extends Model
{
    /** @use HasFactory<PackVersionFactory> */
    use HasFactory;

    /**
     * Where this release's artifacts live on the `packs` disk (§5).
     */
    public static function directoryFor(string $slug, int $version): string
    {
        return $slug.'/v'.$version;
    }

    /**
     * @param  Builder<PackVersion>  $query
     */
    public function scopePublished(Builder $query): void
    {
        $query->whereNotNull('published_at');
    }

    /**
     * @return BelongsTo<Pack, $this>
     */
    public function pack(): BelongsTo
    {
        return $this->belongsTo(Pack::class);
    }

    /**
     * The manifest's per-file map — the *only* list of paths the delta route
     * will serve, which is also what makes it traversal-proof (§7.2).
     *
     * @return array<string, array{bytes: int, sha256: string}>
     */
    public function files(): array
    {
        $files = $this->manifest['files'] ?? [];

        if (! is_array($files)) {
            return [];
        }

        $normalised = [];

        foreach ($files as $path => $meta) {
            if (! is_string($path) || ! is_array($meta)) {
                continue;
            }

            $normalised[$path] = [
                'bytes' => (int) ($meta['bytes'] ?? 0),
                'sha256' => (string) ($meta['sha256'] ?? ''),
            ];
        }

        return $normalised;
    }

    /**
     * The unpacked copy of `$path` on the `packs` disk, for delta downloads.
     */
    public function filePath(string $slug, string $path): string
    {
        return self::directoryFor($slug, $this->version).'/files/'.$path;
    }

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'manifest' => 'array',
            'version' => 'integer',
            'archive_bytes' => 'integer',
            'published_at' => 'datetime',
        ];
    }
}
