<?php

namespace App\Services\Mapping;

use App\Models\AuthoredPage;
use Illuminate\Process\Exceptions\ProcessTimedOutException;
use Illuminate\Support\Facades\Process;

/**
 * Runs the game repo's mapping pipeline in headless Godot (BL-24, §10.3).
 *
 * ```
 * <godot> --headless --path <godot project> \
 *     --script tools/generate_region_map.gd -- <mapping source> [--display <page art>] [flags]
 * ```
 *
 * Three details are load-bearing:
 *
 * 1. **The positional argument is the mapping source, not the page.** For a
 *    masked page (BL-9) that is the mask, and `--display` names the art the
 *    artifacts belong to; for an unmasked page the display image is both. Get
 *    this backwards and the ID map is traced from the wrong picture.
 * 2. **Absolute paths pass through the script's `res://` normalisation
 *    untouched**, which is what lets the scratch directory live outside the
 *    Godot project — the server never writes into the game repo.
 * 3. **Every tunable is passed explicitly**, from
 *    `coloringbook.authoring.tuning` plus the page's overrides, rather than
 *    relying on the script's constants. A pinned engine and a pinned set of
 *    thresholds are what make "re-map a fixture page and diff the artifacts"
 *    a meaningful upgrade check (§10.3).
 *
 * A missing or unconfigured binary is a **failed run with a sentence saying
 * so**, not an exception: a box without the engine should show the operator
 * "no headless Godot is configured here" on the page, not a 500 and a page
 * stuck in `running` forever.
 */
class GodotMappingRunner implements MappingRunner
{
    public function run(MappingRequest $request): MappingResult
    {
        $binary = config('coloringbook.godot_binary');

        if (! is_string($binary) || trim($binary) === '') {
            return MappingResult::failed(__(
                'No headless Godot binary is configured on this server (coloringbook.godot_binary), so pages cannot be mapped here.',
            ));
        }

        if (! is_file($binary)) {
            return MappingResult::failed(__('The configured Godot binary :path is not there.', ['path' => $binary]));
        }

        $project = (string) config('coloringbook.authoring.godot_project');

        if (! is_dir($project)) {
            return MappingResult::failed(__('The Godot project directory :path does not exist.', ['path' => $project]));
        }

        $command = [
            $binary,
            '--headless',
            '--path',
            $project,
            '--script',
            (string) config('coloringbook.authoring.mapping_script'),
            '--',
            $request->sourcePath(),
        ];

        if ($request->maskPath !== null) {
            $command[] = '--display';
            $command[] = $request->displayPath;
        }

        foreach (AuthoredPage::TUNING_FLAGS as $name => $flag) {
            if (! array_key_exists($name, $request->tuning)) {
                continue;
            }

            $command[] = $flag;
            $command[] = (string) $request->tuning[$name];
        }

        try {
            $result = Process::timeout((int) config('coloringbook.authoring.mapping_timeout_seconds'))
                ->run($command);
        } catch (ProcessTimedOutException $e) {
            return MappingResult::failed(
                __('The mapping run did not finish inside the time limit.'),
                $e->getMessage(),
            );
        }

        $output = trim($result->output()."\n".$result->errorOutput());

        if (! $result->successful()) {
            return MappingResult::failed($this->reasonFrom($output), $output, $result->exitCode() ?? 1);
        }

        foreach ($request->expectedArtifacts() as $artifact) {
            if (! is_file($artifact)) {
                return MappingResult::failed(
                    __('The pipeline reported success but wrote no :file.', ['file' => basename($artifact)]),
                    $output,
                );
            }
        }

        return MappingResult::succeeded($output);
    }

    /**
     * The pipeline prints its refusals as `FAIL: …`, so the operator gets the
     * one line that says what is wrong with their drawing rather than the whole
     * engine boot log. Falls back to the last non-empty line.
     */
    private function reasonFrom(string $output): string
    {
        $lines = array_values(array_filter(array_map(trim(...), explode("\n", $output)), fn (string $l): bool => $l !== ''));

        foreach ($lines as $line) {
            if (str_starts_with($line, 'FAIL:')) {
                return trim(substr($line, 5));
            }
        }

        return $lines === [] ? __('The mapping run failed without output.') : (string) end($lines);
    }
}
