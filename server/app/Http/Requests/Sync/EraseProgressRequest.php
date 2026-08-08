<?php

namespace App\Http\Requests\Sync;

use Carbon\CarbonImmutable;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;

/**
 * `DELETE /api/v1/sync/progress` — "Erase all progress", pushed up (BL-18).
 *
 * `erased_at` is the instant the grown-up pressed the button on the device,
 * not the instant the request arrived: an erase made offline still has to beat
 * everything painted before it once the tablet reconnects, and the merge
 * compares it against `client_updated_at`, which is device-clock too. Absent
 * means "now", which is what a caller with no clock of its own should send.
 *
 * `profile` is not an `exists` rule, for the reason the other sync requests
 * give: a ULID belonging to another account reads as 404, never as a 422 that
 * confirms it is out there.
 */
class EraseProgressRequest extends FormRequest
{
    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'profile' => ['sometimes', 'nullable', 'string'],
            'erased_at' => ['sometimes', 'nullable', 'date'],
        ];
    }

    public function profileUlid(): ?string
    {
        $profile = $this->input('profile') ?? $this->query('profile');

        return is_string($profile) && $profile !== '' ? $profile : null;
    }

    /**
     * The erase instant, clamped exactly as `client_updated_at` is.
     *
     * The clamp is load-bearing here rather than defensive: this clock censors
     * every state stamped at or before it, so one a decade in the future would
     * keep the shelf empty for a decade, on every device, with nothing a
     * parent could press to undo it. Clamping makes the worst case "the erase
     * happened when it arrived".
     */
    public function erasedAt(): CarbonImmutable
    {
        $value = $this->input('erased_at');

        if (! is_string($value) || $value === '') {
            return CarbonImmutable::now();
        }

        $at = CarbonImmutable::parse($value)->utc();
        $ceiling = CarbonImmutable::now()->addHours((int) config('coloringbook.sync.max_clock_skew_hours'));

        return $at->greaterThan($ceiling) ? CarbonImmutable::now() : $at;
    }
}
