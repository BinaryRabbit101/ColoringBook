<?php

namespace App\Console\Commands;

use App\Actions\Packs\PublishPackDirectory;
use App\Exceptions\PackPublishException;
use Illuminate\Console\Command;

/**
 * `php artisan pack:publish {dir}` — the publisher, until WP5 puts a web UI
 * in front of the same action (DLC_SERVER.md §10.2).
 *
 *     php artisan pack:publish ../packs/forest-friends
 *     php artisan pack:publish ./build/forest --pack=forest-friends --free
 *
 * `{dir}` is a built pack directory: a §7.2 `manifest.json` plus the files it
 * lists. Every publish creates the pack's *next* version — published versions
 * are immutable, so re-running this against a fixed directory is the correct
 * way to ship a change (§7.3).
 *
 * It is also how the test suite seeds a realistic pack, which is deliberate:
 * the download tests exercise the same bytes a player would receive.
 */
class PublishPack extends Command
{
    /** @var string */
    protected $signature = 'pack:publish
        {dir : Path to a built pack directory containing manifest.json}
        {--pack= : Publish under this slug instead of the manifest\'s pack_slug}
        {--free : Mark the pack free — every signed-in account may download it}
        {--paid : Mark the pack paid (Phase 6 sells it; nobody can download it until then)}';

    /** @var string */
    protected $description = 'Validate a built pack directory and publish it as the pack\'s next version';

    public function handle(PublishPackDirectory $publish): int
    {
        $directory = (string) $this->argument('dir');

        if ($this->option('free') === true && $this->option('paid') === true) {
            $this->components->error('--free and --paid contradict each other.');

            return self::INVALID;
        }

        $isFree = match (true) {
            $this->option('free') === true => true,
            $this->option('paid') === true => false,
            default => null,
        };

        $slug = $this->option('pack');

        try {
            $result = $publish->handle($directory, is_string($slug) ? $slug : null, $isFree);
        } catch (PackPublishException $e) {
            $this->components->error('That pack directory cannot be published.');

            foreach ($e->errors as $error) {
                $this->components->bulletList([$error]);
            }

            return self::FAILURE;
        }

        foreach ($result->warnings as $warning) {
            $this->components->warn($warning);
        }

        $version = $result->version;
        $pack = $version->pack;

        $this->components->info(sprintf('Published %s v%d.', $pack->slug, $version->version));

        $this->components->twoColumnDetail('Pack', $pack->title.($pack->is_free ? ' (free)' : ''));
        $this->components->twoColumnDetail('Books', (string) $pack->books()->count());
        $this->components->twoColumnDetail('Min client', (string) $version->min_client_version);
        $this->components->twoColumnDetail('Archive', $version->archive_path);
        $this->components->twoColumnDetail('Bytes', number_format($version->archive_bytes));
        $this->components->twoColumnDetail('sha256', $version->archive_sha256);

        return self::SUCCESS;
    }
}
