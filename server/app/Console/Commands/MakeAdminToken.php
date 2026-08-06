<?php

namespace App\Console\Commands;

use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Console\Command;

/**
 * `php artisan admin:token you@example.com` — the only way an admin token is
 * ever minted.
 *
 * The dev box's `pack build` script POSTs to `/api/v1/admin/*` with one
 * (DLC_SERVER.md §10.2), and there is deliberately no endpoint and no UI
 * button that issues it: a token that can publish a pack should require
 * someone with a shell on the server, not a session that a stolen laptop
 * inherits.
 *
 * It carries exactly the `admin` ability — never the game's `save:sync`,
 * `entitlements:read`, `packs:download` set — so a leaked pack-build token
 * cannot read anybody's colouring, and a leaked device token cannot publish.
 */
class MakeAdminToken extends Command
{
    protected $signature = 'admin:token
        {email : The parent account (users.is_admin must already be set)}
        {--name=pack-build : A label, so the token can be found and revoked}
        {--days=90 : How long it lives; 0 for no expiry}';

    protected $description = 'Mint a Sanctum token with the admin ability, for the pack-build script';

    public function handle(): int
    {
        /** @var User|null $user */
        $user = User::query()->where('email', $this->argument('email'))->first();

        if ($user === null) {
            $this->components->error(sprintf('No account with the email "%s".', $this->argument('email')));

            return self::FAILURE;
        }

        if (! $user->is_admin) {
            // Minting the token would be pointless: EnsureAdmin checks the
            // column on every request, not the ability alone.
            $this->components->error(sprintf('"%s" is not an admin (users.is_admin is false).', $user->email));

            return self::FAILURE;
        }

        $days = (int) $this->option('days');

        $token = $user->createToken(
            (string) $this->option('name'),
            [(string) config('coloringbook.admin.ability')],
            $days > 0 ? CarbonImmutable::now()->addDays($days) : null,
        );

        $this->components->info('Admin token created. It is shown once.');
        $this->line($token->plainTextToken);

        return self::SUCCESS;
    }
}
