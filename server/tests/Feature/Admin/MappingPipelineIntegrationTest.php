<?php

namespace Tests\Feature\Admin;

use App\Services\Mapping\GodotMappingRunner;
use App\Services\Mapping\MappingRequest;
use App\Services\PackValidation;
use App\Services\PageArtifacts;
use Tests\Concerns\AuthorsBooks;
use Tests\TestCase;

/**
 * The one thing the fake cannot prove: that headless Godot, given a page, comes
 * back with artifacts this server considers valid (BL-24, §10.3).
 *
 * **Opt-in, and deliberately outside the gate.** It skips unless
 * `COLORINGBOOK_GODOT_BINARY` names a real engine, so `composer test` stays
 * green on a box with no Godot — which is most of them, and all of CI:
 *
 * ```
 * COLORINGBOOK_GODOT_BINARY="/path/to/Godot_v4.5.1-stable_win64.exe" \
 *     php artisan test --filter=MappingPipelineIntegrationTest
 * ```
 *
 * This is also the check §10.3 asks for when the pinned engine moves: an engine
 * upgrade is a content-pipeline change, so re-map a fixture page and look at
 * what came out before trusting it with a book.
 */
class MappingPipelineIntegrationTest extends TestCase
{
    use AuthorsBooks;

    private string $workspace = '';

    protected function setUp(): void
    {
        parent::setUp();

        $binary = env('COLORINGBOOK_GODOT_BINARY');
        $project = env('COLORINGBOOK_GODOT_PROJECT', base_path('../godot'));

        if (! is_string($binary) || ! is_file($binary)) {
            $this->markTestSkipped('No headless Godot binary — set COLORINGBOOK_GODOT_BINARY to run this.');
        }

        if (! is_string($project) || ! is_dir($project)) {
            $this->markTestSkipped('The Godot project directory is not there.');
        }

        config([
            'coloringbook.godot_binary' => $binary,
            'coloringbook.authoring.godot_project' => $project,
        ]);

        $this->workspace = storage_path('app/private/staging/integration-'.bin2hex(random_bytes(6)));
        mkdir($this->workspace, 0775, true);
    }

    protected function tearDown(): void
    {
        if ($this->workspace !== '' && is_dir($this->workspace)) {
            foreach ((array) glob($this->workspace.'/*') as $file) {
                if (is_string($file)) {
                    @unlink($file);
                }
            }

            @rmdir($this->workspace);
        }

        parent::tearDown();
    }

    public function test_the_real_pipeline_produces_artifacts_this_server_validates(): void
    {
        $display = $this->workspace.DIRECTORY_SEPARATOR.'page_01.png';
        copy($this->pagesFixturePath('valid').DIRECTORY_SEPARATOR.'page_01.png', $display);

        // The fixture is 16x16, so the shipped defaults (which drop anything
        // under 64 px as a speck) would throw the whole page away. Tuning per
        // page is exactly what the overrides are for.
        $request = new MappingRequest($display, null, ['min_area' => 4, 'dilate' => 0]);

        $result = (new GodotMappingRunner)->run($request);

        $this->assertTrue($result->successful, 'Pipeline output: '.$result->output);
        $this->assertFileExists($request->idmapPath());
        $this->assertFileExists($request->regionsPath());

        $verdict = (new PackValidation)->validatePage(new PageArtifacts(
            'integration page',
            $display,
            $request->idmapPath(),
            $request->regionsPath(),
        ));

        $this->assertSame([], $verdict->errors, implode("\n", $verdict->errors));
    }
}
