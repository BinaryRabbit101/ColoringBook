<?php

namespace Tests\Unit;

use App\Services\Mapping\MappingRequest;
use PHPUnit\Framework\TestCase;

/**
 * The pipeline's file-naming contract (BL-24, §10.3).
 *
 * These look like string arithmetic and are not. The mapping pipeline writes
 * its artifacts *beside the display image, named from its basename*, and every
 * one of these expectations is the difference between reading back the file the
 * run produced and reading back nothing at all.
 */
class MappingRequestTest extends TestCase
{
    public function test_artifacts_are_named_from_the_display_image(): void
    {
        $request = new MappingRequest('/tmp/work/page_01.png');

        $this->assertSame('/tmp/work/page_01_idmap.png', $request->idmapPath());
        $this->assertSame('/tmp/work/page_01_regions.json', $request->regionsPath());
    }

    public function test_an_unmasked_page_maps_from_its_own_display_image(): void
    {
        // BL-9: every page has a detail image; the mask is optional, and
        // without one the display art is its own mapping source.
        $request = new MappingRequest('/tmp/work/page_01.png');

        $this->assertSame('/tmp/work/page_01.png', $request->sourcePath());
        $this->assertNull($request->maskArtifactPath());
        $this->assertSame(
            ['/tmp/work/page_01_idmap.png', '/tmp/work/page_01_regions.json'],
            $request->expectedArtifacts(),
        );
    }

    public function test_a_masked_page_maps_from_the_mask_and_expects_a_resample(): void
    {
        $request = new MappingRequest('/tmp/work/page_01.png', '/tmp/work/source/mask.png');

        $this->assertSame('/tmp/work/source/mask.png', $request->sourcePath());
        // BL-12: the resample ships, and it is named after the *page*.
        $this->assertSame('/tmp/work/page_01_mask.png', $request->maskArtifactPath());
        $this->assertContains('/tmp/work/page_01_mask.png', $request->expectedArtifacts());
    }

    public function test_the_mask_source_is_never_staged_where_the_resample_lands(): void
    {
        // The one staging mistake that would have a run silently overwrite its
        // own input.
        $request = new MappingRequest('/tmp/work/page_01.png', '/tmp/work/source/mask.png');

        $this->assertNotSame($request->maskArtifactPath(), $request->maskPath);
    }
}
