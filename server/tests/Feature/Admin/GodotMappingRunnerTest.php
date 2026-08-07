<?php

namespace Tests\Feature\Admin;

use App\Models\AuthoredPage;
use App\Services\Mapping\GodotMappingRunner;
use App\Services\Mapping\MappingRequest;
use Illuminate\Support\Facades\Process;
use Tests\TestCase;

/**
 * The shell-out itself, with the process faked (BL-24, §10.3).
 *
 * What is worth pinning down here is the **command line**, because it is the
 * whole contract with `generate_region_map.gd`: the positional argument is the
 * mapping source (the mask when there is one — BL-9), `--display` names the
 * page the artifacts belong to, and every tunable is passed explicitly so a run
 * is reproducible from the log it prints.
 *
 * And the two configuration failures, because they are the ones a fresh box
 * actually hits: no binary configured, and a binary that is not there. Both
 * must come back as a *sentence on the page*, never an exception — a page that
 * says "no headless Godot is configured here" is debuggable; a 500 and a row
 * stuck at `running` is not.
 */
class GodotMappingRunnerTest extends TestCase
{
    public function test_a_box_with_no_engine_says_so_instead_of_throwing(): void
    {
        config(['coloringbook.godot_binary' => null]);

        $result = (new GodotMappingRunner)->run(new MappingRequest('/tmp/page_01.png'));

        $this->assertFalse($result->successful);
        $this->assertStringContainsString('No headless Godot binary is configured', (string) $result->reason);
    }

    public function test_a_configured_binary_that_is_not_there_is_reported_too(): void
    {
        config(['coloringbook.godot_binary' => '/nowhere/godot.exe']);

        $result = (new GodotMappingRunner)->run(new MappingRequest('/tmp/page_01.png'));

        $this->assertFalse($result->successful);
        $this->assertStringContainsString('/nowhere/godot.exe', (string) $result->reason);
    }

    public function test_an_unmasked_run_passes_the_display_image_as_the_source(): void
    {
        Process::fake();
        $this->configureEngine();

        (new GodotMappingRunner)->run(new MappingRequest('/tmp/work/page_01.png'));

        Process::assertRan(function ($process): bool {
            $command = $this->commandOf($process);

            $this->assertStringContainsString('--headless', $command);
            $this->assertStringContainsString('tools/generate_region_map.gd', $command);
            $this->assertStringContainsString('/tmp/work/page_01.png', $command);
            // No mask, so nothing to point --display at.
            $this->assertStringNotContainsString('--display', $command);

            return true;
        });
    }

    public function test_a_masked_run_passes_the_mask_first_and_names_the_page_with_display(): void
    {
        Process::fake();
        $this->configureEngine();

        (new GodotMappingRunner)->run(
            new MappingRequest('/tmp/work/page_01.png', '/tmp/work/source/mask.png'),
        );

        Process::assertRan(function ($process): bool {
            $command = $this->commandOf($process);

            $this->assertStringContainsString('/tmp/work/source/mask.png', $command);
            $this->assertStringContainsString('--display', $command);

            return true;
        });
    }

    public function test_every_tuning_knob_is_passed_explicitly(): void
    {
        Process::fake();
        $this->configureEngine();

        (new GodotMappingRunner)->run(new MappingRequest(
            '/tmp/work/page_01.png',
            null,
            ['dilate' => 3, 'min_area' => 128],
        ));

        Process::assertRan(function ($process): bool {
            $command = $this->commandOf($process);

            $this->assertStringContainsString('--dilate', $command);
            $this->assertStringContainsString('--min-area', $command);
            // Every flag the pipeline has, by its own name.
            $this->assertSame('--dilate', AuthoredPage::TUNING_FLAGS['dilate']);

            return true;
        });
    }

    public function test_a_pipeline_refusal_is_reduced_to_its_fail_line(): void
    {
        $this->configureEngine();

        Process::fake([
            '*' => Process::result(
                output: "Godot Engine v4.5.1\nSource: page_01.png (16x16)",
                errorOutput: 'FAIL: region #000001 covers 97.0% of the paintable pixels',
                exitCode: 1,
            ),
        ]);

        $result = (new GodotMappingRunner)->run(new MappingRequest('/tmp/work/page_01.png'));

        $this->assertFalse($result->successful);
        $this->assertSame('region #000001 covers 97.0% of the paintable pixels', $result->reason);
        // The whole log survives for the editor's "pipeline output" panel.
        $this->assertStringContainsString('Godot Engine v4.5.1', $result->output);
    }

    public function test_a_run_that_claims_success_but_wrote_nothing_is_a_failure(): void
    {
        $this->configureEngine();
        Process::fake(['*' => Process::result(output: 'done', exitCode: 0)]);

        $result = (new GodotMappingRunner)->run(new MappingRequest('/tmp/work/page_01.png'));

        $this->assertFalse($result->successful);
        $this->assertStringContainsString('page_01_idmap.png', (string) $result->reason);
    }

    /**
     * Point the config at a real file and a real directory so the runner gets
     * as far as the process call. Neither is ever executed — the process is
     * faked.
     */
    private function configureEngine(): void
    {
        config([
            'coloringbook.godot_binary' => base_path('artisan'),
            'coloringbook.authoring.godot_project' => base_path(),
        ]);
    }

    private function commandOf(mixed $process): string
    {
        /** @var object{command: array<int, string>|string} $process */
        $command = $process->command;

        return is_array($command) ? implode(' ', $command) : $command;
    }
}
