<?php

namespace App\Models;

// use Illuminate\Contracts\Auth\MustVerifyEmail;
use Database\Factories\UserFactory;
use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Attributes\Hidden;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;
use Laravel\Fortify\Contracts\PasskeyUser;
use Laravel\Fortify\PasskeyAuthenticatable;
use Laravel\Fortify\TwoFactorAuthenticatable;
use Laravel\Sanctum\HasApiTokens;
use Laravel\Sanctum\PersonalAccessToken;
use Laravel\Sanctum\TransientToken;

/**
 * @property int $id
 * @property string $ulid
 * @property string|null $name
 * @property string $email
 * @property Carbon|null $email_verified_at
 * @property string $password
 * @property bool $is_admin
 * @property string|null $two_factor_secret
 * @property string|null $two_factor_recovery_codes
 * @property Carbon|null $two_factor_confirmed_at
 * @property string|null $remember_token
 * @property Carbon|null $created_at
 * @property Carbon|null $updated_at
 * @property-read Collection<int, ChildProfile> $childProfiles
 * @property-read Collection<int, Device> $devices
 * @property-read Collection<int, Entitlement> $entitlements
 */
#[Fillable(['name', 'email', 'password'])]
#[Hidden(['password', 'two_factor_secret', 'two_factor_recovery_codes', 'remember_token'])]
class User extends Authenticatable implements PasskeyUser
{
    /**
     * A dashboard request authenticates through the session, so the "current
     * access token" may be Sanctum's `TransientToken` rather than a real row.
     * Saying so here keeps the distinction visible to anything that wants to
     * slide an expiry or revoke a device.
     *
     * @use HasFactory<UserFactory>
     * @use HasApiTokens<PersonalAccessToken|TransientToken>
     */
    use HasApiTokens, HasFactory, Notifiable, PasskeyAuthenticatable, TwoFactorAuthenticatable;

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
     * The children colouring under this account.
     *
     * @return HasMany<ChildProfile, $this>
     */
    public function childProfiles(): HasMany
    {
        return $this->hasMany(ChildProfile::class)->orderBy('id');
    }

    /**
     * Every install that has ever signed in on this account.
     *
     * @return HasMany<Device, $this>
     */
    public function devices(): HasMany
    {
        return $this->hasMany(Device::class)->orderByDesc('last_seen_at');
    }

    /**
     * Every pack this account has a claim on, revoked ones included — the
     * server is the entitlement authority, the client never decides
     * (DLC_SERVER.md §9). Scope with `->live()` for "currently owns".
     *
     * @return HasMany<Entitlement, $this>
     */
    public function entitlements(): HasMany
    {
        return $this->hasMany(Entitlement::class);
    }

    /**
     * What the dashboard calls this parent. Accounts created from the game
     * have no name — email is the only thing we ever asked for (§4.1).
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
            'two_factor_confirmed_at' => 'datetime',
        ];
    }
}
