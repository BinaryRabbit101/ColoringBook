<?php

namespace App\Http\Requests\Sync;

use Carbon\CarbonImmutable;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;

/**
 * `POST /api/v1/sync/paint/{book_uid}/{page}` — the sha-first check of §6.3.
 *
 * `bytes` is the client's claim about the upload it is *about* to make, which
 * is why it is validated against the size cap here: refusing a 40 MB upload
 * costs one small request instead of 40 MB of transfer.
 *
 * `profile` is not an `exists` rule, for the same reason it isn't in
 * `FetchProgressRequest`: a ULID belonging to another account must read as a
 * 404, not as a 422 that confirms the row is out there.
 */
class NegotiatePaintRequest extends FormRequest
{
    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'profile' => ['sometimes', 'nullable', 'string'],
            'sha256' => ['required', 'string', 'regex:/^[0-9a-f]{64}$/'],
            // Deliberately no `max` rule: the cap is enforced by
            // `PaintUploads::assertSize()` so that a too-big page gets the same
            // stable `PAINT_TOO_LARGE` code here as it would on the PUT,
            // rather than a generic VALIDATION_FAILED on one and not the other.
            'bytes' => ['required', 'integer', 'min:1'],
            'client_painted_at' => ['required', 'date'],
        ];
    }

    public function profileUlid(): ?string
    {
        $profile = $this->input('profile');

        return is_string($profile) && $profile !== '' ? $profile : null;
    }

    public function sha256(): string
    {
        return (string) $this->input('sha256');
    }

    public function bytes(): int
    {
        return (int) $this->input('bytes');
    }

    public function clientPaintedAt(): CarbonImmutable
    {
        return CarbonImmutable::parse((string) $this->input('client_painted_at'))->utc();
    }
}
