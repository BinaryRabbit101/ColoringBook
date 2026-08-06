<?php

namespace App\Actions\Admin;

use App\Actions\Packs\PublishedPack;
use App\Actions\Packs\PublishPackDirectory;
use App\Exceptions\ApiException;
use App\Exceptions\PackPublishException;
use App\Services\PackManifest;
use App\Services\PackManifestValidator;
use App\Services\PackValidation;
use Symfony\Component\HttpFoundation\Response;

/**
 * `POST /admin/packs/{slug}/versions` — validate a staged pack directory and
 * create the release as a **draft** (DLC_SERVER.md §10.2).
 *
 * Two validators run here, and the order matters:
 *
 * 1. `PackManifestValidator` — structural. Does the manifest parse, does every
 *    path it names exist with the digest it claims, is every `book_uid`
 *    unique and unclaimed.
 * 2. `PackValidation` — §10.1's pixel checks. Do the ID map and the display
 *    art agree, does the regions JSON describe the ID map that shipped beside
 *    it, is there a giant region.
 *
 * The pixel checks only run once the structure holds, because "the regions
 * JSON disagrees with the ID map" is noise when the reason is that neither
 * file is the one the manifest listed. Within a layer, **every** problem is
 * reported at once — the operator is running a build script and wants the
 * whole list, not one round trip per typo.
 *
 * On success `PublishPackDirectory` does the import with `$publishNow = false`,
 * so every artifact is written and every catalog row exists while
 * `published_at` stays null. Nothing is visible to `GET /packs` until a human
 * has looked at the region-overlay preview and pressed publish.
 */
class SubmitPackVersion
{
    public function __construct(
        private readonly PackManifestValidator $structural,
        private readonly PackValidation $pixels,
        private readonly PublishPackDirectory $publisher,
    ) {}

    /**
     * @param  string  $directory  A staged pack directory (see `StagePackDirectory`).
     *
     * @throws ApiException when the pack does not validate
     */
    public function handle(string $directory, ?string $slug = null, ?bool $isFree = null): PublishedPack
    {
        $manifestPath = $directory.DIRECTORY_SEPARATOR.PackManifest::FILENAME;

        if (! is_file($manifestPath)) {
            throw self::rejection([sprintf('%s is missing from the upload.', PackManifest::FILENAME)]);
        }

        try {
            $manifest = PackManifest::fromJson((string) file_get_contents($manifestPath));
        } catch (PackPublishException $e) {
            throw self::rejection($e->errors);
        }

        // Validate against the slug the release is actually filed under, so
        // the "book_uid belongs to another pack" check cannot misfire.
        if ($slug !== null && $slug !== '') {
            $manifest = new PackManifest([...$manifest->data, 'pack_slug' => $slug]);
        }

        $errors = $this->structural->validate($manifest, $directory);
        $warnings = [];

        if ($errors === []) {
            $result = $this->pixels->validate($manifest, $directory);
            $errors = $result->errors;
            $warnings = $result->warnings;
        }

        if ($errors !== []) {
            throw self::rejection($errors, $warnings);
        }

        try {
            $published = $this->publisher->handle($directory, $slug, $isFree, publishNow: false);
        } catch (PackPublishException $e) {
            throw self::rejection($e->errors, $warnings);
        }

        return new PublishedPack($published->version, [...$warnings, ...$published->warnings]);
    }

    /**
     * §11's `{version, warnings[], errors[]}` for the failing case: a 422 whose
     * `details` carry the full list, in the house error shape.
     *
     * Static and public because staging the upload happens *before* this
     * action gets a directory to look at — a zip with a traversal path in it
     * is refused by `StagePackDirectory`, and the caller has to be able to
     * report that as the same failure rather than as a 500.
     *
     * @param  array<int, string>  $errors
     * @param  array<int, string>  $warnings
     */
    public static function rejection(array $errors, array $warnings = []): ApiException
    {
        return new ApiException(
            'PACK_VALIDATION_FAILED',
            __('That pack did not validate.'),
            Response::HTTP_UNPROCESSABLE_ENTITY,
            ['errors' => array_values($errors), 'warnings' => array_values($warnings)],
        );
    }
}
