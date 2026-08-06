<?php

namespace App\Http\Requests\Sync;

use Carbon\CarbonImmutable;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;

/**
 * `GET /api/v1/sync/progress?profile=&since=`.
 *
 * `profile` is not validated as `exists` on purpose: a ULID belonging to
 * another account has to read as 404, not as a 422 that confirms the row is
 * out there. The controller resolves it through the signed-in user instead.
 */
class FetchProgressRequest extends FormRequest
{
    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'profile' => ['sometimes', 'nullable', 'string'],
            'since' => ['sometimes', 'nullable', 'date'],
        ];
    }

    public function profileUlid(): ?string
    {
        $profile = $this->query('profile');

        return is_string($profile) && $profile !== '' ? $profile : null;
    }

    /**
     * The cursor: rows whose server-side `updated_at` is strictly after this.
     * Absent means "everything".
     */
    public function since(): ?CarbonImmutable
    {
        $since = $this->query('since');

        return is_string($since) && $since !== ''
            ? CarbonImmutable::parse($since)->utc()
            : null;
    }
}
