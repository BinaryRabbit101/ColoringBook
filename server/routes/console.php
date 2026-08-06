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
