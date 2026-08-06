<?php

namespace App\Http\Controllers\Admin;

use App\Actions\Admin\PublishPackVersion;
use App\Actions\Admin\StagePackDirectory;
use App\Actions\Admin\SubmitPackVersion;
use App\Concerns\ResolvesAdminPacks;
use App\Exceptions\ApiException;
use App\Exceptions\PackPublishException;
use App\Http\Controllers\Controller;
use App\Http\Requests\Admin\StorePackRequest;
use App\Http\Requests\Admin\StorePackVersionRequest;
use App\Http\Resources\AdminPackResource;
use App\Http\Resources\AdminPackVersionResource;
use App\Models\Pack;
use App\Services\PackPreview;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Http\UploadedFile;
use Inertia\Inertia;
use Inertia\Response as InertiaResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * The Inertia half of the admin tool — session auth, the same actions and the
 * same FormRequests as `/api/v1/admin/*`.
 *
 * That sharing is the point. The dev box's `pack build` script and the browser
 * reach identical validation, identical draft semantics and identical publish
 * rules; the only difference is that one gets JSON and the other gets a page.
 *
 * Where the API answers a validation failure with a 422 and a list, the UI
 * bounces back to the pack page with the same list in the session, because a
 * reviewer needs to read six problems at once and fix the build — not to be
 * shown the first one in a red box under a file input.
 */
class PackController extends Controller
{
    use ResolvesAdminPacks;

    public function index(): InertiaResponse
    {
        $packs = Pack::query()
            ->with('versions')
            ->orderBy('sort_order')
            ->orderBy('title')
            ->get();

        return Inertia::render('admin/Packs', [
            'packs' => $packs->map(fn (Pack $pack): AdminPackResource => new AdminPackResource($pack))->all(),
        ]);
    }

    public function show(Request $request, string $slug): InertiaResponse
    {
        $pack = $this->adminPack($slug, withVersions: true);

        return Inertia::render('admin/Pack', [
            'pack' => new AdminPackResource($pack),
            'versions' => AdminPackVersionResource::collection($pack->versions),
            // Populated by a bounced upload; empty on a plain visit.
            'validationErrors' => $request->session()->get('pack_errors', []),
            'validationWarnings' => $request->session()->get('pack_warnings', []),
        ]);
    }

    public function store(StorePackRequest $request): RedirectResponse
    {
        /** @var array{slug: string, title: string, blurb?: string|null, is_free?: bool, sort_order?: int} $attributes */
        $attributes = $request->validated();

        $pack = new Pack;
        $pack->fill($attributes);
        $pack->status = Pack::STATUS_DRAFT;
        $pack->save();

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Pack created.')]);

        return to_route('admin.packs.show', ['slug' => $pack->slug]);
    }

    public function storeVersion(
        StorePackVersionRequest $request,
        string $slug,
        StagePackDirectory $stage,
        SubmitPackVersion $submit,
    ): RedirectResponse {
        $pack = $this->adminPack($slug);

        /** @var UploadedFile|null $archive */
        $archive = $request->file('archive');

        if ($archive === null) {
            return back()->withErrors(['archive' => __('Choose a built pack zip to upload.')]);
        }

        try {
            $directory = $stage->fromZip($archive);
        } catch (PackPublishException $e) {
            return $this->bounce($pack, $e->errors);
        }

        try {
            $published = $submit->handle($directory, $pack->slug);
        } catch (ApiException $e) {
            /** @var array<int, string> $errors */
            $errors = is_array($e->details['errors'] ?? null) ? $e->details['errors'] : [$e->getMessage()];

            /** @var array<int, string> $warnings */
            $warnings = is_array($e->details['warnings'] ?? null) ? $e->details['warnings'] : [];

            return $this->bounce($pack, $errors, $warnings);
        } finally {
            $stage->discard($directory);
        }

        Inertia::flash('toast', [
            'type' => 'success',
            'message' => __('Draft v:version created — review the preview before publishing.', [
                'version' => $published->version->version,
            ]),
        ]);

        return to_route('admin.packs.show', ['slug' => $pack->slug])
            ->with('pack_warnings', array_values($published->warnings));
    }

    public function preview(string $slug, int $version, PackPreview $preview): InertiaResponse
    {
        $pack = $this->adminPack($slug);
        $packVersion = $this->adminVersion($pack, $version);

        return Inertia::render('admin/Preview', [
            'pack' => new AdminPackResource($pack),
            'version' => new AdminPackVersionResource($packVersion),
            'pages' => array_map(
                fn (array $page): array => [
                    ...$page,
                    'preview_url' => route('admin.packs.versions.preview.page', [
                        'slug' => $pack->slug,
                        'version' => $packVersion->version,
                        'book' => $page['book_uid'],
                        'page' => $page['page_index'],
                    ]),
                ],
                $preview->pages($packVersion),
            ),
        ]);
    }

    /**
     * The composited overlay itself. A plain `<img src>` target, so it has to
     * be a session-authenticated route rather than the token API's.
     */
    public function previewPage(
        string $slug,
        int $version,
        string $book,
        int $page,
        PackPreview $preview,
    ): Response {
        $packVersion = $this->adminVersion($this->adminPack($slug), $version);

        return response($preview->render($packVersion, $book, $page), Response::HTTP_OK, [
            'Content-Type' => 'image/png',
            'Cache-Control' => 'private, max-age=3600',
        ]);
    }

    public function publish(string $slug, int $version, PublishPackVersion $publish): RedirectResponse
    {
        $pack = $this->adminPack($slug);
        $publish->handle($this->adminVersion($pack, $version));

        Inertia::flash('toast', [
            'type' => 'success',
            'message' => __('v:version published.', ['version' => $version]),
        ]);

        return to_route('admin.packs.show', ['slug' => $pack->slug]);
    }

    /**
     * Send the operator back to the pack with the *whole* list of problems.
     *
     * @param  array<int, string>  $errors
     * @param  array<int, string>  $warnings
     */
    private function bounce(Pack $pack, array $errors, array $warnings = []): RedirectResponse
    {
        Inertia::flash('toast', ['type' => 'error', 'message' => __('That pack did not validate.')]);

        return to_route('admin.packs.show', ['slug' => $pack->slug])
            ->with('pack_errors', array_values($errors))
            ->with('pack_warnings', array_values($warnings));
    }
}
