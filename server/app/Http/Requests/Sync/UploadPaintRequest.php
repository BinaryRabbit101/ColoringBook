<?php

namespace App\Http\Requests\Sync;

use Carbon\CarbonImmutable;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;

/**
 * `PUT /api/v1/sync/paint/{book_uid}/{page}?sha256=&client_painted_at=` — the
 * upload itself.
 *
 * The body is the PNG and nothing else, so everything that would otherwise be
 * a JSON field rides in the query string. The client does not have to
 * assemble that URL: `POST` hands back the exact one to `PUT` to, query and
 * headers included.
 *
 * `sha256` is the **negotiated** digest — the same value the `POST` was
 * answered on. Carrying it separately from `Content-Digest` is what makes the
 * check meaningful: the header proves the bytes survived the wire, the query
 * parameter proves they are the bytes both ends agreed to move.
 */
class UploadPaintRequest extends FormRequest
{
    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'profile' => ['sometimes', 'nullable', 'string'],
            'sha256' => ['required', 'string', 'regex:/^[0-9a-f]{64}$/'],
            'client_painted_at' => ['required', 'date'],
        ];
    }

    public function profileUlid(): ?string
    {
        $profile = $this->query('profile');

        return is_string($profile) && $profile !== '' ? $profile : null;
    }

    /**
     * The digest the client and server negotiated, lower-case hex.
     */
    public function negotiatedSha256(): string
    {
        return strtolower((string) $this->query('sha256'));
    }

    public function clientPaintedAt(): CarbonImmutable
    {
        return CarbonImmutable::parse((string) $this->query('client_painted_at'))->utc();
    }

    /**
     * The `Content-Digest` header's sha-256 member as lower-case hex, or null
     * when the header is missing or names no sha-256 we can read.
     *
     * RFC 9530 spells it `sha-256=:<base64>:`. The older RFC 3230 `Digest:
     * SHA-256=<base64>` form is accepted too — some HTTP stacks (Godot's
     * included) are easier to drive with one than the other, and both carry
     * the same claim.
     */
    public function bodyDigest(): ?string
    {
        foreach (['Content-Digest', 'Digest'] as $header) {
            $value = $this->header($header);

            if (! is_string($value) || $value === '') {
                continue;
            }

            if (preg_match('/sha-?256=:?([A-Za-z0-9+\/=_-]+?):?(,|$)/i', $value, $matches) !== 1) {
                continue;
            }

            $raw = base64_decode(strtr($matches[1], '-_', '+/'), true);

            if ($raw === false || strlen($raw) !== 32) {
                continue;
            }

            return bin2hex($raw);
        }

        return null;
    }
}
