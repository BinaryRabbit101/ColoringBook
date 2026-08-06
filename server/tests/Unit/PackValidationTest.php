<?php

namespace Tests\Unit;

use App\Services\PackValidation;
use App\Services\PageArtifacts;
use Tests\Concerns\AdminsPacks;
use Tests\TestCase;

/**
 * §10.1, one failure at a time.
 *
 * Each fixture under `tests/Fixtures/pages/<case>` is a real page that is
 * broken in exactly one way, so a test can assert both that the right problem
 * was found *and* that nothing else was — a validator that reports six errors
 * for one mistake is as useless as one that reports none.
 */
class PackValidationTest extends TestCase
{
    use AdminsPacks;

    private function validate(string $case, ?array $size = null, ?int $regionCount = null): array
    {
        $page = new PageArtifacts(
            $case,
            $this->pageFixturePath($case).DIRECTORY_SEPARATOR.'page_01.png',
            $this->pageFixturePath($case).DIRECTORY_SEPARATOR.'page_01_idmap.png',
            $this->pageFixturePath($case).DIRECTORY_SEPARATOR.'page_01_regions.json',
            $size,
            $regionCount,
        );

        return app(PackValidation::class)->validatePage($page)->errors;
    }

    public function test_gd_is_available(): void
    {
        // Without it there is no §10.1 validation and no preview at all, so a
        // missing extension should fail here rather than mysteriously later.
        $this->assertTrue(extension_loaded('gd'));
    }

    public function test_a_matching_pair_validates(): void
    {
        $result = app(PackValidation::class)->validatePage(
            PageArtifacts::inDirectory($this->pageFixturePath('valid')),
        );

        $this->assertSame([], $result->errors);
        $this->assertSame([], $result->warnings);
        $this->assertTrue($result->passed());
    }

    public function test_the_manifests_declared_size_and_region_count_are_checked_too(): void
    {
        $this->assertSame([], $this->validate('valid', [16, 16], 4));

        $errors = $this->validate('valid', [2048, 2048], 9);

        $this->assertCount(2, $errors);
        $this->assertStringContainsString('image_size [2048, 2048]', $errors[0]);
        $this->assertStringContainsString('region_count 9', $errors[1]);
    }

    public function test_display_and_idmap_must_have_identical_dimensions(): void
    {
        $errors = $this->validate('dimension-mismatch');

        $this->assertCount(1, $errors);
        $this->assertStringContainsString('12x16', $errors[0]);
        $this->assertStringContainsString('16x16', $errors[0]);
    }

    public function test_a_json_id_missing_from_the_idmap_is_an_error(): void
    {
        $errors = $this->validate('json-id-missing-from-idmap');

        $this->assertCount(1, $errors);
        $this->assertStringContainsString('1 region id(s) in the regions JSON are absent', $errors[0]);
        $this->assertStringContainsString('#000005', $errors[0]);
    }

    public function test_an_idmap_colour_missing_from_the_json_is_an_error(): void
    {
        // The other direction, which a one-way check would sail straight past.
        $errors = $this->validate('idmap-colour-missing-from-json');

        $this->assertCount(1, $errors);
        $this->assertStringContainsString('1 colour(s) in the ID map are absent', $errors[0]);
        $this->assertStringContainsString('#000004', $errors[0]);
    }

    public function test_an_idmap_without_black_line_work_is_an_error(): void
    {
        $errors = $this->validate('no-black');

        $this->assertCount(1, $errors);
        $this->assertStringContainsString('#000000', $errors[0]);
    }

    public function test_one_giant_region_is_an_error(): void
    {
        $errors = $this->validate('giant-region');

        $this->assertCount(1, $errors);
        $this->assertStringContainsString('#000001', $errors[0]);
        // 192 of 196 paintable pixels.
        $this->assertStringContainsString('98.0%', $errors[0]);
        $this->assertStringContainsString('gap in the line art', $errors[0]);
    }

    public function test_the_giant_region_threshold_is_configurable(): void
    {
        config()->set('coloringbook.admin.giant_region_fraction', 0.99);

        $this->assertSame([], $this->validate('giant-region'));
    }

    public function test_a_regions_json_traced_at_another_size_is_an_error(): void
    {
        $errors = $this->validate('image-size-mismatch');

        $this->assertCount(1, $errors);
        $this->assertStringContainsString('traced at 8x8', $errors[0]);
    }

    public function test_an_unsupported_regions_schema_is_an_error(): void
    {
        $errors = $this->validate('bad-schema');

        $this->assertCount(1, $errors);
        $this->assertStringContainsString('schema version 2', $errors[0]);
    }

    public function test_a_missing_artifact_is_left_to_the_structural_validator(): void
    {
        $page = new PageArtifacts(
            'ghost page',
            $this->pageFixturePath('valid').DIRECTORY_SEPARATOR.'nope.png',
            $this->pageFixturePath('valid').DIRECTORY_SEPARATOR.'page_01_idmap.png',
            $this->pageFixturePath('valid').DIRECTORY_SEPARATOR.'page_01_regions.json',
        );

        $this->assertFalse($page->complete());
    }
}
