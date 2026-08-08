<?php

namespace App\Http\Requests\Sync;

use App\Services\ProgressMerge;
use App\Services\ProgressPush;
use App\Services\ProgressState;
use Carbon\CarbonImmutable;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

/**
 * `PUT /api/v1/sync/progress` — the whole shelf in one batched call (§11).
 *
 * Page statuses are validated strictly against the three the merge rule knows.
 * That matters more than it looks: an unrecognised status ranks as `untouched`
 * in `ProgressMerge`, so letting one through would quietly make a typo lose to
 * every other value forever rather than being reported as the client bug it is.
 */
class SyncProgressRequest extends FormRequest
{
    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'profile' => ['sometimes', 'nullable', 'string'],

            'books' => ['required', 'array', 'min:1', 'max:'.$this->maxBooks()],

            // Authored identifiers (§6.1) — never a filename, never a res:// path.
            'books.*.book_uid' => ['required', 'string', 'max:64', 'regex:/^[A-Za-z0-9._-]+$/', 'distinct'],

            // 0 means "I have never synced this book".
            'books.*.base_revision' => ['required', 'integer', 'min:0'],

            'books.*.current_page_index' => ['required', 'integer', 'min:0'],
            'books.*.furthest_page_index' => ['required', 'integer', 'min:0'],

            'books.*.page_statuses' => ['required', 'array', 'max:'.$this->maxPages()],
            'books.*.page_statuses.*' => ['required', 'string', Rule::in(ProgressMerge::statuses())],

            'books.*.client_updated_at' => ['required', 'date'],

            // BL-18: the per-page "Start over" clocks, index-parallel to
            // `page_statuses`. Nullable *elements*, because a list with a hole
            // in it is exactly what "page 3 was reset and the others were not"
            // looks like on the wire.
            'books.*.page_erased_at' => ['sometimes', 'array', 'max:'.$this->maxPages()],
            'books.*.page_erased_at.*' => ['nullable', 'date'],
        ];
    }

    /**
     * @return array<string, string>
     */
    public function messages(): array
    {
        return [
            'books.*.book_uid.distinct' => __('The same book was sent twice in one request.'),
        ];
    }

    public function profileUlid(): ?string
    {
        $profile = $this->input('profile');

        return is_string($profile) && $profile !== '' ? $profile : null;
    }

    /**
     * The validated payload, as the value objects the domain works in.
     *
     * @return list<ProgressPush>
     */
    public function pushes(): array
    {
        /** @var array<int, array<string, mixed>> $books */
        $books = $this->validated('books', []);

        return array_values(array_map(
            fn (array $book): ProgressPush => new ProgressPush(
                (string) $book['book_uid'],
                (int) $book['base_revision'],
                new ProgressState(
                    (int) $book['current_page_index'],
                    $this->statuses($book['page_statuses'] ?? []),
                    (int) $book['furthest_page_index'],
                    $this->clientUpdatedAt((string) $book['client_updated_at']),
                    $this->erasures($book['page_erased_at'] ?? []),
                ),
            ),
            $books,
        ));
    }

    /**
     * @return list<string>
     */
    private function statuses(mixed $statuses): array
    {
        return is_array($statuses)
            ? array_values(array_map(static fn (mixed $s): string => (string) $s, $statuses))
            : [];
    }

    /**
     * The per-page erase clocks (BL-18), clamped by the same rule as
     * `client_updated_at`.
     *
     * The clamp matters more here than there: an erase clock censors every
     * status stamped at or before it, so one stamped a decade ahead would keep
     * a page blank on every device for a decade. Clamping to the server's now
     * makes the worst case "the reset happened when it arrived".
     *
     * @return list<CarbonImmutable|null>
     */
    private function erasures(mixed $erasures): array
    {
        if (! is_array($erasures)) {
            return [];
        }

        return ProgressState::trim(array_values(array_map(
            fn (mixed $at): ?CarbonImmutable => is_string($at) && $at !== ''
                ? $this->clientUpdatedAt($at)
                : null,
            $erasures,
        )));
    }

    /**
     * Clamp a client clock that is implausibly far ahead down to the server's
     * now (§6.3's sanity clamp, `coloringbook.sync.max_clock_skew_hours`).
     *
     * Progress clamps where paint rejects. A tablet whose clock is a decade
     * out must still be able to save a child's colouring — and clamping is the
     * stricter answer anyway: left alone, that timestamp would win
     * `current_page_index` against every other device for the next decade.
     * Past timestamps are never touched; an old save legitimately is old.
     */
    private function clientUpdatedAt(string $value): CarbonImmutable
    {
        $timestamp = CarbonImmutable::parse($value)->utc();
        $ceiling = CarbonImmutable::now()->addHours((int) config('coloringbook.sync.max_clock_skew_hours'));

        return $timestamp->greaterThan($ceiling) ? CarbonImmutable::now() : $timestamp;
    }

    private function maxBooks(): int
    {
        return (int) config('coloringbook.sync.max_books_per_request');
    }

    private function maxPages(): int
    {
        return (int) config('coloringbook.sync.max_pages_per_book');
    }
}
