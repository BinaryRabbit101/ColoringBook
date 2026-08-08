<?php

namespace App\Actions\Authoring;

use App\Actions\Admin\PublishPackVersion;
use App\Actions\Admin\SubmitPackVersion;
use App\Exceptions\ApiException;
use App\Models\AuthoredSticker;
use App\Models\AuthoredStickerSet;
use App\Models\Pack;
use App\Models\PackVersion;
use App\Services\Authoring\AuthoringWorkspace;
use App\Services\PackManifest;
use Illuminate\Database\Eloquent\Collection;
use Symfony\Component\HttpFoundation\Response;

/**
 * `POST /admin/sticker-sets/{set_uid}/publish` — the one button, for stickers
 * (BL-37).
 *
 * Deliberately the same shape as `PublishAuthoredBook`, minus the half that does
 * not apply:
 *
 * 1. **It refuses**, with the *whole* list of reasons in the operator's
 *    language, while any sticker is failing validation or the set is empty.
 * 2. **It writes a §7.2 pack directory and hands it to the existing publish
 *    path** — `SubmitPackVersion` (structural, then `StickerValidation` instead
 *    of §10.1's pixel checks) followed by `PublishPackVersion`. There is **no
 *    second publisher**: every `pack_versions` row in this application comes out
 *    of `PublishPackDirectory`, which is what makes "versions are monotonic per
 *    pack and immutable once published" a property rather than a promise.
 *
 * What is NOT here is the whole point of BL-37's server half: there is no
 * mapping step, no headless Godot, no queue and no waiting. A sticker has no
 * regions, so the gate is image validation, and it already ran when the file
 * was uploaded.
 */
class PublishAuthoredStickerSet
{
    public function __construct(
        private readonly AuthoringWorkspace $workspace,
        private readonly SubmitPackVersion $submit,
        private readonly PublishPackVersion $publish,
    ) {}

    /**
     * @throws ApiException when the set is not in a publishable state
     */
    public function handle(AuthoredStickerSet $set): PackVersion
    {
        /** @var Collection<int, AuthoredSticker> $stickers */
        $stickers = $set->stickers()->get();

        $blockers = $set->publishBlockers($stickers);

        if ($blockers !== []) {
            throw self::refusal($blockers);
        }

        $directory = $this->workspace->create('publish-stickers');

        try {
            $manifest = $this->build($set, $stickers, $directory);

            file_put_contents(
                $directory.DIRECTORY_SEPARATOR.PackManifest::FILENAME,
                (string) json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE),
            );

            $draft = $this->submit->handle($directory, $set->pack->slug, $set->pack->is_free);

            return $this->publish->handle($draft->version);
        } finally {
            $this->workspace->discard($directory);
        }
    }

    /**
     * Lay the pack out on disk and describe it — §7.2's sticker layout:
     *
     * ```
     * stickers/<set_uid>/sticker_set.json   synthesised by the publisher
     * stickers/<set_uid>/<sticker_id>.png
     * ```
     *
     * Files are named after the **stable `sticker_id`**, never the index: an
     * index moves when the operator reorders the set, and a delta update would
     * then re-download every file after the one that moved (§7.4, BL-26).
     *
     * The pack cover is the FIRST sticker's image — a one-set pack has nothing
     * else to be a cover, and content addressing means one blob wearing two
     * `assets.kind` hats costs one file, exactly as a one-book pack's cover does.
     *
     * @param  Collection<int, AuthoredSticker>  $stickers
     * @return array<string, mixed>
     */
    private function build(AuthoredStickerSet $set, Collection $stickers, string $directory): array
    {
        $files = [];
        $entries = [];
        $cover = null;

        foreach ($stickers as $sticker) {
            $path = sprintf('stickers/%s/%s', $set->set_uid, $sticker->fileName());
            $this->place($sticker, $path, $directory, $files);
            $cover ??= $path;

            $entry = [
                'sticker_index' => $sticker->sticker_index,
                'sticker_id' => $sticker->sticker_id,
                'title' => $sticker->title,
                'image' => $path,
            ];

            // BL-38: an animated sticker is a sprite sheet plus this object;
            // a still one carries **no `anim` key at all**, which is what every
            // sticker published before BL-38 looks like and what a client that
            // has never heard of animation reads.
            if ($sticker->anim !== null) {
                $entry['anim'] = $sticker->anim;
            }

            $entries[] = $entry;
        }

        return [
            'manifest_version' => (int) config('coloringbook.packs.manifest_version'),
            'kind' => Pack::KIND_STICKER_SET,
            'pack_slug' => $set->pack->slug,
            'title' => $set->pack->title,
            'blurb' => $set->blurb,
            'cover' => $cover,
            'is_free' => $set->pack->is_free,
            'min_client_version' => (string) config('coloringbook.packs.default_min_client_version'),
            'sticker_sets' => [[
                'set_uid' => $set->set_uid,
                'title' => $set->title,
                'sort_order' => $set->sort_order,
                'cover' => $cover,
                'stickers' => $entries,
            ]],
            'files' => $files,
        ];
    }

    /**
     * Materialise one sticker's image into the pack directory and record its
     * digest, measured from the file that was just written rather than copied
     * off the `assets` row — so the manifest describes what is actually in the
     * directory (`PackManifestValidator` re-checks both).
     *
     * @param  array<string, array{bytes: int, sha256: string}>  $files
     */
    private function place(AuthoredSticker $sticker, string $path, string $directory, array &$files): void
    {
        $asset = $sticker->imageAsset;

        $target = $directory.DIRECTORY_SEPARATOR.str_replace('/', DIRECTORY_SEPARATOR, $path);

        if (! $this->workspace->materialise($asset, $target)) {
            throw self::refusal([sprintf(
                '%s: %s',
                $sticker->label(),
                __('its image is no longer on disk — upload it again.'),
            )]);
        }

        $files[$path] = [
            'bytes' => (int) filesize($target),
            'sha256' => (string) hash_file('sha256', $target),
        ];
    }

    /**
     * The house error shape, carrying every reason at once — the same
     * `{errors, warnings}` `details` block the book publisher and the pack
     * upload door answer with, so the browser and the API render one thing.
     *
     * @param  array<int, string>  $errors
     */
    public static function refusal(array $errors): ApiException
    {
        return new ApiException(
            'STICKER_SET_NOT_PUBLISHABLE',
            __('This sticker set is not ready to publish.'),
            Response::HTTP_UNPROCESSABLE_ENTITY,
            ['errors' => array_values($errors), 'warnings' => []],
        );
    }
}
