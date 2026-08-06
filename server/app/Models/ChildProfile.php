<?php

namespace App\Models;

use Database\Factories\ChildProfileFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;

/**
 * A child on a parent's account: a nickname, an avatar index, a default mode.
 *
 * There is deliberately no `age_band`, no email, no name — nothing about the
 * child beyond what the game needs to open the right shelf in the right
 * palette (DLC_SERVER.md §4.1, SERVER_BUILD_PLAN.md Q12). The nickname is
 * free text but never leaves the account: it is rendered in the game and in
 * the parent's dashboard, nowhere else.
 *
 * @property int $id
 * @property string $ulid
 * @property int $user_id
 * @property string $nickname
 * @property int $avatar_index
 * @property string $default_mode
 * @property Carbon|null $created_at
 * @property Carbon|null $updated_at
 * @property-read User $user
 */
#[Fillable(['nickname', 'avatar_index', 'default_mode'])]
class ChildProfile extends Model
{
    /** @use HasFactory<ChildProfileFactory> */
    use HasFactory;

    /**
     * @var array<string, mixed>
     */
    protected $attributes = [
        'avatar_index' => 0,
        'default_mode' => 'child',
    ];

    /**
     * The public identifier used on every API surface — never the numeric key.
     */
    public function getRouteKeyName(): string
    {
        return 'ulid';
    }

    /**
     * @return BelongsTo<User, $this>
     */
    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    protected static function booted(): void
    {
        static::creating(function (ChildProfile $profile): void {
            if (blank($profile->ulid)) {
                $profile->ulid = (string) Str::ulid();
            }
        });
    }

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'avatar_index' => 'integer',
        ];
    }
}
