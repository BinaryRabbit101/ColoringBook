<?php

use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

/*
 * WP4 — expire the retained losing paint versions (DLC_SERVER.md §6.3).
 *
 * Nightly, off-peak, and without overlap: the sweep is per-file work and a
 * long one must not have a second copy walking the same rows. Nothing here is
 * urgent — a picture whose 30 days ran out at breakfast can go at 03:20.
 */
Schedule::command('paint:prune')
    ->dailyAt('03:20')
    ->withoutOverlapping();

/*
 * BL-24 — drain the queue (the per-page mapping jobs, DLC_SERVER.md §10.3).
 *
 * The mini-pc has no resident queue worker; its every-minute schedule:run cron
 * is the house pattern, so the worker rides it. --stop-when-empty bounds each
 * run, --timeout must outlast a mapping run (coloringbook.authoring
 * mapping_timeout_seconds, 600 — a first run also imports the Godot project),
 * and withoutOverlapping stops a second worker picking up the same job. On the
 * dev box `composer dev` runs its own worker; this drain finding an empty
 * queue there is a no-op.
 */
Schedule::command('queue:work --stop-when-empty --tries=1 --timeout=660 --memory=512')
    ->everyMinute()
    ->withoutOverlapping(15);
