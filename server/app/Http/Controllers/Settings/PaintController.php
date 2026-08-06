<?php

namespace App\Http\Controllers\Settings;

use App\Actions\Sync\RestorePaintLayer;
use App\Http\Controllers\Controller;
use App\Models\BookProgress;
use App\Models\RetainedPaintLayer;
use App\Models\User;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Inertia\Inertia;
use Inertia\Response as InertiaResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * The parent dashboard's pictures page — "restore the older picture" (§6.3).
 *
 * This is the visible half of the paint safety net. Two devices painting the
 * same page cannot be merged, so one of them loses; the loser is kept for 30
 * days and this page is where a parent gets it back. It lists *only* pages
 * that actually have an older version, because a page with nothing to restore
 * is nothing for a parent to think about.
 *
 * Deliberately dashboard-only. A game token can push and pull paint all day,
 * but choosing between two versions of a child's picture is a grown-up's
 * decision made on a grown-up's screen (§4.1), and a five year old must never
 * be shown that choice (§6.3).
 */
class PaintController extends Controller
{
    public function index(Request $request): InertiaResponse
    {
        return Inertia::render('settings/Pictures', [
            'books' => $this->shelves($this->user($request)),
            'retentionDays' => (int) config('coloringbook.paint.retention_days'),
        ]);
    }

    public function restore(Request $request, string $retained, RestorePaintLayer $restore): RedirectResponse
    {
        $model = $this->find($this->user($request), $retained);

        $restore->handle($model);

        Inertia::flash('toast', ['type' => 'success', 'message' => __('Picture restored.')]);

        return to_route('pictures.edit');
    }

    /**
     * Every book on the account that has at least one restorable page.
     *
     * @return list<array<string, mixed>>
     */
    private function shelves(User $user): array
    {
        $progress = BookProgress::query()
            ->where('user_id', $user->id)
            ->with([
                'childProfile',
                'paintLayers' => fn ($query) => $query->orderBy('page_index'),
                'paintLayers.retainedVersions',
            ])
            ->orderBy('book_uid')
            ->get();

        $books = [];

        foreach ($progress as $shelf) {
            $pages = [];

            foreach ($shelf->paintLayers as $layer) {
                if ($layer->retainedVersions->isEmpty()) {
                    continue;
                }

                $pages[] = [
                    // 1-based for a human: page 1 is the first page of the
                    // book, which is also what the file is called on disk.
                    'page_number' => $layer->page_index + 1,
                    'current_painted_at' => $layer->client_painted_at->toIso8601String(),
                    'older' => $layer->retainedVersions->map(fn (RetainedPaintLayer $retained): array => [
                        'ulid' => $retained->ulid,
                        'painted_at' => $retained->client_painted_at->toIso8601String(),
                        'retained_at' => $retained->retained_at->toIso8601String(),
                        'expires_at' => $retained->retained_at
                            ->addDays((int) config('coloringbook.paint.retention_days'))
                            ->toIso8601String(),
                        'bytes' => $retained->bytes,
                    ])->all(),
                ];
            }

            if ($pages === []) {
                continue;
            }

            $books[] = [
                'book_uid' => $shelf->book_uid,
                'shelf' => $shelf->childProfile?->nickname,
                'pages' => $pages,
            ];
        }

        return $books;
    }

    /**
     * A retained version, resolved *through* the account.
     *
     * Another household's picture is a 404 rather than a 403, the same rule
     * the profile and device pages follow: an id that isn't yours does not get
     * confirmed as existing.
     */
    private function find(User $user, string $ulid): RetainedPaintLayer
    {
        return RetainedPaintLayer::query()
            ->where('ulid', $ulid)
            ->whereHas('paintLayer.bookProgress', fn ($query) => $query->where('user_id', $user->id))
            ->firstOrFail();
    }

    private function user(Request $request): User
    {
        $user = $request->user();

        abort_unless($user instanceof User, Response::HTTP_UNAUTHORIZED);

        return $user;
    }
}
