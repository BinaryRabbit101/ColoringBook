<?php

namespace App\Models;

use Carbon\CarbonImmutable;
use Database\Factories\AssetFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Str;

/**
 * A content-addressed original: one file, stored under its own sha256.
 *
 * `storage_path` is `<sha256[0:2]>/<sha256>` on the `assets` disk
 * (DLC_SERVER.md §5) — re-importing identical art is free, and integrity is
 * checkable without touching the database.
 *
 * @property int $id
 * @property string $ulid
 * @property string $kind
 * @property string $storage_path
 * @property int $bytes
 * @property string $sha256
 * @property string $mime
 * @property int|null $width
 * @property int|null $height
 * @property CarbonImmutable|null $created_at
 * @property CarbonImmutable|null $updated_at
 */
#[Fillable(['kind', 'storage_path', 'bytes', 'sha256', 'mime', 'width', 'height'])]
class Asset extends Model
{
    /** @use HasFactory<AssetFactory> */
    use HasFactory;

    /**
     * The artifact roles a page (or a pack) is made of. `mask` is stored but
     * never shipped, and is optional per page (BL-9 / §7.2).
     */
    public const KINDS = ['display', 'mask', 'idmap', 'regions', 'cover'];

    /**
     * Where these bytes live on the `assets` disk, for a given digest.
     */
    public static function pathFor(string $sha256): string
    {
        return substr($sha256, 0, 2).'/'.$sha256;
    }

    /**
     * The public identifier used on every API surface — never the numeric key.
     */
    public function getRouteKeyName(): string
    {
        return 'ulid';
    }

    protected static function booted(): void
    {
        static::creating(function (Asset $asset): void {
            if (blank($asset->ulid)) {
                $asset->ulid = (string) Str::ulid();
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
            'width' => 'integer',
            'height' => 'integer',
        ];
    }
}
