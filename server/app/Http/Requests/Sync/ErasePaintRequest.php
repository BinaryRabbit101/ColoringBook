<?php

namespace App\Http\Requests\Sync;

use Carbon\CarbonImmutable;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;

/**
 * `DELETE /api/v1/sync/paint/{book_uid}/{page}` — the page's "Start over"
 * (BL-7), pushed up as a state rather than left as an absence (BL-18).
 *
 * `client_erased_at` is the device clock at the moment the child confirmed the
 * reset, and it is the *whole* comparison: it decides last-write-wins against
 * the stored picture exactly as `client_painted_at` would, and it becomes the
 * page's erase clock so the page's status cannot climb back to `complete` on
 * the next merge.
 *
 * The clock skew rule is paint's, not progress's — **reject, don't clamp**
 * (see `PaintUploads::sane()`). An erase stamped three years ahead would keep
 * the page blank against every later drawing for three years, which is the
 * same failure a picture stamped three years ahead causes, and rejection is
 * the recoverable answer to both.
 */
class ErasePaintRequest extends FormRequest
{
    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'profile' => ['sometimes', 'nullable', 'string'],
            'client_erased_at' => ['sometimes', 'nullable', 'date'],
        ];
    }

    public function profileUlid(): ?string
    {
        $profile = $this->input('profile') ?? $this->query('profile');

        return is_string($profile) && $profile !== '' ? $profile : null;
    }

    /**
     * The erase instant. Absent means "now" — a caller with no clock of its
     * own (curl, the dashboard) should not have to invent one.
     */
    public function clientErasedAt(): CarbonImmutable
    {
        $value = $this->input('client_erased_at') ?? $this->query('client_erased_at');

        return is_string($value) && $value !== ''
            ? CarbonImmutable::parse($value)->utc()
            : CarbonImmutable::now();
    }
}
