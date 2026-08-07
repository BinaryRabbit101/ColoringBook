<?php

namespace App\Jobs;

use App\Actions\Admin\StoreAssetFile;
use App\Models\Asset;
use App\Models\AuthoredPage;
use App\Services\Authoring\AuthoringWorkspace;
use App\Services\Mapping\MappingRequest;
use App\Services\Mapping\MappingRunner;
use App\Services\PackValidation;
use App\Services\PageArtifacts;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\Storage;
use Throwable;

/**
 * Map one authored page: run the pipeline, keep what it wrote, and say what
 * §10.1 makes of it (BL-24, DLC_SERVER.md §10.3).
 *
 * Queued because a 2048² page is tens of seconds of flood fill and contour
 * tracing, and the operator pressed "upload", not "wait". The page row carries
 * the whole state machine — `pending → queued → running → mapped | failed` —
 * so the editor can poll one endpoint and always have something honest to show.
 *
 * ## The shape of a run
 *
 * 1. Stage a scratch directory: the display art at `page_01.png`, and (only
 *    when the page has one) the artist's mask at `source/mask.png`. The mask
 *    goes *somewhere else* deliberately — `page_01_mask.png` is the path the
 *    pipeline writes its resample to, and staging the input there would have
 *    the run overwrite its own source.
 * 2. Hand it to the `MappingRunner`. One implementation shells out to headless
 *    Godot; the test suite binds a fake. There is no PHP mapping code anywhere
 *    in this application and there must never be (§10.1).
 * 3. Store `page_01_idmap.png`, `page_01_regions.json` and, on a masked page,
 *    the resampled `page_01_mask.png` as content-addressed assets. The
 *    artist's original mask stays as its own asset so the page can be re-mapped
 *    later against an improved pipeline without chasing them for the file.
 * 4. Run `PackValidation` — the same pixel checks the pack-upload door uses —
 *    and store the verdict. Mapping and validating are separate verdicts: a
 *    page can map perfectly and still be unpublishable because one region
 *    swallowed the drawing, which means a line has a gap and the art must
 *    change.
 *
 * **Nothing here throws on a bad page.** A failed mapping is a state on the
 * row, not an exception: the queue retrying a drawing with a gap in it would
 * produce the same failure three times and lose the message.
 */
class MapAuthoredPage implements ShouldQueue
{
    use Queueable;

    /**
     * A page that will not map does not map better the second time — every
     * genuine failure here is about the artwork or the box's configuration.
     */
    public int $tries = 1;

    public function __construct(public readonly int $pageId)
    {
        /** @var string|null $queue */
        $queue = config('coloringbook.authoring.queue');

        if ($queue !== null && $queue !== '') {
            $this->onQueue($queue);
        }
    }

    public function handle(
        MappingRunner $runner,
        AuthoringWorkspace $workspace,
        StoreAssetFile $assets,
        PackValidation $validation,
    ): void {
        $page = AuthoredPage::query()->find($this->pageId);

        if ($page === null) {
            // Deleted while queued. Nothing to do, and nothing to complain
            // about — the operator already moved on.
            return;
        }

        $page->forceFill(['mapping_status' => AuthoredPage::STATUS_RUNNING])->save();

        $directory = $workspace->create('mapping');

        try {
            $request = $this->stage($page, $workspace, $directory);

            if ($request === null) {
                $this->fail($page, __('The page artwork is no longer on disk — re-upload it.'));

                return;
            }

            $result = $runner->run($request);

            if (! $result->successful) {
                $this->fail($page, $result->reason ?? __('The mapping run failed.'), $result->output);

                return;
            }

            $this->keep($page, $request, $assets, $validation, $result->output);
        } catch (Throwable $e) {
            $this->fail($page, $e->getMessage());
        } finally {
            $workspace->discard($directory);
        }
    }

    /**
     * Lay the page out the way the pipeline expects, or null when a blob has
     * gone missing from the assets disk.
     */
    private function stage(AuthoredPage $page, AuthoringWorkspace $workspace, string $directory): ?MappingRequest
    {
        $display = $directory.DIRECTORY_SEPARATOR.'page_01.png';

        if (! $workspace->materialise($page->displayAsset, $display)) {
            return null;
        }

        $maskPath = null;
        $mask = $page->maskAsset;

        if ($mask !== null) {
            // Not `page_01_mask.png`: that is the pipeline's *output* path.
            $maskPath = $directory.DIRECTORY_SEPARATOR.'source'.DIRECTORY_SEPARATOR.'mask.png';

            if (! $workspace->materialise($mask, $maskPath)) {
                return null;
            }
        }

        return new MappingRequest($display, $maskPath, $page->effectiveTuning());
    }

    /**
     * Store the artifacts and the §10.1 verdict.
     */
    private function keep(
        AuthoredPage $page,
        MappingRequest $request,
        StoreAssetFile $assets,
        PackValidation $validation,
        string $output,
    ): void {
        $idmap = $assets->handle($request->idmapPath(), 'idmap');
        $regions = $assets->handle($request->regionsPath(), 'regions');

        $maskArtifactPath = $request->maskArtifactPath();
        $maskArtifact = $maskArtifactPath !== null
            ? $assets->handle($maskArtifactPath, 'mask')
            : null;

        $verdict = $validation->validatePage(new PageArtifacts(
            $page->label(),
            $request->displayPath,
            $request->idmapPath(),
            $request->regionsPath(),
        ));

        $page->forceFill([
            'idmap_asset_id' => $idmap->id,
            'regions_asset_id' => $regions->id,
            'mask_artifact_asset_id' => $maskArtifact?->id,
            'image_w' => $idmap->width,
            'image_h' => $idmap->height,
            'region_count' => $this->regionCount($regions),
            'mapping_status' => AuthoredPage::STATUS_MAPPED,
            'mapping_error' => null,
            'mapping_log' => $this->tail($output),
            'mapped_at' => now(),
            'validation_errors' => $verdict->errors,
            'validation_warnings' => $verdict->warnings,
        ])->save();
    }

    /**
     * How many regions the pipeline traced, read from the JSON it just wrote —
     * the manifest's `region_count` has to agree with it, and `PackValidation`
     * checks exactly that at publish time.
     */
    private function regionCount(Asset $regions): ?int
    {
        $bytes = Storage::disk((string) config('coloringbook.storage.assets_disk'))
            ->get($regions->storage_path);

        if (! is_string($bytes)) {
            return null;
        }

        /** @var mixed $decoded */
        $decoded = json_decode($bytes, true);

        if (! is_array($decoded) || ! is_array($decoded['regions'] ?? null)) {
            return null;
        }

        return count($decoded['regions']);
    }

    private function fail(AuthoredPage $page, string $reason, string $output = ''): void
    {
        $page->forceFill([
            'mapping_status' => AuthoredPage::STATUS_FAILED,
            'mapping_error' => $reason,
            'mapping_log' => $this->tail($output),
            'validation_errors' => null,
            'validation_warnings' => null,
        ])->save();
    }

    /**
     * The engine prints a boot banner on every run; the interesting part is
     * always the end, and the column is not a log store.
     */
    private function tail(string $output, int $lines = 40): ?string
    {
        $output = trim($output);

        if ($output === '') {
            return null;
        }

        $all = explode("\n", $output);

        return implode("\n", array_slice($all, -$lines));
    }
}
