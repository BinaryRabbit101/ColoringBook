<?php

namespace Tests\Feature\Console;

use App\Models\PaintLayer;
use App\Models\RetainedPaintLayer;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Console\Scheduling\Event;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Storage;
use Tests\Concerns\PaintsPages;
use Tests\TestCase;

/**
 * `php artisan paint:prune` — the 30-day end of the retention promise (§6.3).
 */
class PaintPruneTest extends TestCase
{
    use PaintsPages, RefreshDatabase;

    /**
     * Paint a page twice, so there is exactly one retained loser.
     */
    private function contest(?CarbonImmutable $when = null): User
    {
        $this->travelTo($when ?? CarbonImmutable::parse('2026-08-06 09:00:00'));

        $user = User::factory()->create();
        $bearer = $this->issueDeviceToken($user);

        $this->upload($bearer, 'coyote-2026', 0, $this->png('first'))->assertCreated();
        $this->upload($bearer, 'coyote-2026', 0, $this->png('second'), CarbonImmutable::now()->addMinute())
            ->assertCreated();

        return $user;
    }

    public function test_a_retained_picture_past_the_window_goes_with_its_file(): void
    {
        $disk = $this->fakePaintStorage();
        $this->contest();

        $path = RetainedPaintLayer::query()->sole()->storage_path;
        $disk->assertExists($path);

        $this->travel(31)->days();

        $this->artisan('paint:prune')
            ->expectsOutputToContain('Pruned 1')
            ->assertSuccessful();

        $this->assertDatabaseCount('retained_paint_layers', 0);
        $disk->assertMissing($path);

        // The live picture is untouched, however old it is.
        $this->assertDatabaseCount('paint_layers', 1);
        $disk->assertExists(PaintLayer::query()->sole()->storage_path);
    }

    public function test_a_retained_picture_inside_the_window_is_left_alone(): void
    {
        $disk = $this->fakePaintStorage();
        $this->contest();

        $path = RetainedPaintLayer::query()->sole()->storage_path;

        $this->travel(29)->days();

        $this->artisan('paint:prune')->assertSuccessful();

        $this->assertDatabaseCount('retained_paint_layers', 1);
        $disk->assertExists($path);
    }

    public function test_the_window_can_be_overridden_for_one_run(): void
    {
        $disk = $this->fakePaintStorage();
        $this->contest();

        $path = RetainedPaintLayer::query()->sole()->storage_path;

        $this->travel(2)->days();

        $this->artisan('paint:prune', ['--days' => 1])->assertSuccessful();

        $this->assertDatabaseCount('retained_paint_layers', 0);
        $disk->assertMissing($path);
    }

    public function test_pretend_reports_without_deleting(): void
    {
        $disk = $this->fakePaintStorage();
        $this->contest();

        $path = RetainedPaintLayer::query()->sole()->storage_path;

        $this->travel(31)->days();

        $this->artisan('paint:prune', ['--pretend' => true])
            ->expectsOutputToContain('1 retained picture(s) are past 30 days')
            ->assertSuccessful();

        $this->assertDatabaseCount('retained_paint_layers', 1);
        $disk->assertExists($path);
    }

    public function test_a_zero_day_window_is_refused(): void
    {
        $this->fakePaintStorage();

        // "Retained for 30 days" is a promise to a parent. A sweep that keeps
        // nothing is a typo, not an instruction.
        $this->artisan('paint:prune', ['--days' => 0])->assertExitCode(2);
    }

    public function test_the_retention_days_config_is_what_the_sweep_reads(): void
    {
        $disk = $this->fakePaintStorage();
        config(['coloringbook.paint.retention_days' => 3]);

        $this->contest();
        $path = RetainedPaintLayer::query()->sole()->storage_path;

        $this->travel(4)->days();

        $this->artisan('paint:prune')->assertSuccessful();

        $this->assertDatabaseCount('retained_paint_layers', 0);
        $disk->assertMissing($path);
    }

    public function test_the_sweep_is_scheduled_daily(): void
    {
        /** @var Schedule $schedule */
        $schedule = $this->app->make(Schedule::class);

        $commands = array_map(
            static fn (Event $event): string => (string) $event->command,
            $schedule->events(),
        );

        $matching = array_values(array_filter(
            $commands,
            static fn (string $command): bool => str_contains($command, 'paint:prune'),
        ));

        $this->assertCount(1, $matching, 'paint:prune is not on the schedule.');
    }

    public function test_pruning_an_empty_shelf_is_a_no_op(): void
    {
        Storage::fake((string) config('coloringbook.storage.paint_disk'));

        $this->artisan('paint:prune')
            ->expectsOutputToContain('Pruned 0')
            ->assertSuccessful();
    }
}
