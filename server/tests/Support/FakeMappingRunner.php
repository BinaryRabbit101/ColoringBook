<?php

namespace Tests\Support;

use App\Services\Mapping\MappingRequest;
use App\Services\Mapping\MappingResult;
use App\Services\Mapping\MappingRunner;

/**
 * The mapping pipeline, without the engine.
 *
 * `composer test` has to stay green on a box with no Godot — CI, a fresh
 * checkout, the mini-pc before its binary is pinned — and a 160 MB engine is
 * not a test dependency. So this drops **pre-baked fixture artifacts** into the
 * exact paths the real run would have written, which exercises every line on
 * both sides of the process boundary: the staging, the artifact naming, the
 * content-addressed store, the §10.1 verdict and the state machine on the row.
 *
 * What it deliberately does *not* do is map anything. The one thing this fake
 * cannot prove is that headless Godot produces those bytes — which is what the
 * opt-in `MappingPipelineIntegrationTest` is for, and why an engine upgrade is
 * a content-pipeline change rather than a dependency bump (§10.3).
 */
class FakeMappingRunner implements MappingRunner
{
    /**
     * Every request it was handed, in order — so a test can assert *which*
     * image was used as the mapping source, which is the whole of BL-9.
     *
     * @var list<MappingRequest>
     */
    public array $requests = [];

    /**
     * @param  string  $fixtureDirectory  A `tests/Fixtures/pages/<case>`
     *                                    directory: `page_01_idmap.png` and
     *                                    `page_01_regions.json` are copied out
     *                                    of it.
     * @param  string|null  $failWith  When set, every run refuses with this
     *                                 reason instead — the "a line has a gap"
     *                                 path.
     */
    public function __construct(
        private readonly string $fixtureDirectory,
        private readonly ?string $failWith = null,
    ) {}

    public function run(MappingRequest $request): MappingResult
    {
        $this->requests[] = $request;

        if ($this->failWith !== null) {
            return MappingResult::failed($this->failWith, 'FAIL: '.$this->failWith);
        }

        copy($this->fixture('page_01_idmap.png'), $request->idmapPath());
        copy($this->fixture('page_01_regions.json'), $request->regionsPath());

        // BL-12: a masked run also writes the mask resampled to the display
        // image's resolution. The fixtures are already one size, so the
        // "resample" is the mask itself — which is exactly what the real
        // pipeline writes when the two already match.
        $maskArtifact = $request->maskArtifactPath();

        if ($maskArtifact !== null && $request->maskPath !== null) {
            copy($request->maskPath, $maskArtifact);
        }

        return MappingResult::succeeded("Tunables: fake\nWrote fixture artifacts.");
    }

    private function fixture(string $file): string
    {
        return $this->fixtureDirectory.DIRECTORY_SEPARATOR.$file;
    }
}
