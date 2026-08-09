<?php

namespace App\Models;

use Database\Factories\UserFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Attributes\Hidden;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;
use Laravel\Sanctum\HasApiTokens;
use Laravel\Sanctum\PersonalAccessToken;
use Laravel\Sanctum\TransientToken;

/**
 * An **operator** — the person who signs in to the publishing tool.
 *
 * There are no player accounts. A game device is its own identity
 * (`App\Models\Device`), owns its own entitlements, and never links to a row
 * here. `users` exists solely so `/admin/*` has somebody to authenticate, and
 * `is_admin` is the whole authorisation model (DLC_SERVER.md §10.2).
 *
 * Rows are created by `database/seeders`, `php artisan tinker` or a migration —
 * there is deliberately no registration route anywhere in the application.
 *
 * @property int $id
 * @property string $ulid
 * @property string|null $name
 * @property string $email
 * @property Carbon|null $email_verified_at
 * @property string $password
 * @property bool $is_admin
 * @property string|null $remember_token
 * @property Carbon|null $created_at
 * @property Carbon|null $updated_at
 */
#[Fillable(['name', 'email', 'password'])]
#[Hidden(['password', 'remember_token'])]
class User extends Authenticatable
{
    /**
     * A dashboard request authenticates through the session, so the "current
     * access token" may be Sanctum's `TransientToken` rather than a real row.
     * The only real tokens a user ever holds are admin tokens minted by
     * `php artisan admin:token` for the dev box's pack-build script.
     *
     * @use HasFactory<UserFactory>
     * @use HasApiTokens<PersonalAccessToken|TransientToken>
     */
    use HasApiTokens, HasFactory, Notifiable;

    /**
     * Defaults that match the schema, so a freshly made model reads the same
     * as one round-tripped through the database.
     *
     * @var array<string, mixed>
     */
    protected $attributes = [
        'is_admin' => false,
    ];

    /**
     * The public identifier used on every API surface — never the numeric key.
     */
    public function getRouteKeyName(): string
    {
        return 'ulid';
    }

    /**
     * What the dashboard calls this operator.
     */
    public function displayName(): string
    {
        return blank($this->name) ? $this->email : $this->name;
    }

    /**
     * Mint the public ULID as the row is created.
     */
    protected static function booted(): void
    {
        static::creating(function (User $user): void {
            if (blank($user->ulid)) {
                $user->ulid = (string) Str::ulid();
            }
        });
    }

    /**
     * Get the attributes that should be cast.
     *
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'email_verified_at' => 'datetime',
            'password' => 'hashed',
            'is_admin' => 'boolean',
        ];
    }
}
