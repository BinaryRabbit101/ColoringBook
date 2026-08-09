<?php

namespace App\Actions\Admin;

use App\Exceptions\ApiException;
use App\Models\Entitlement;
use App\Models\Pack;
use App\Models\User;
use App\Services\EntitlementOwner;
use App\Services\Entitlements;
use Symfony\Component\HttpFoundation\Response;

/**
 * `POST /admin/entitlements` — hand a household a pack (DLC_SERVER.md §11).
 *
 * Until payments land (Phase 6) this is the only way a paid pack reaches an
 * account, so it is also the support desk's "we're sorry, here" button. It
 * addresses the account by **email**, because that is the only identifier a
 * parent can read off a support email — the API never asks an operator to
 * copy a ULID out of a database.
 *
 * It is a *re-*grant, deliberately: `Entitlements::grant()` refuses to touch an
 * existing row, so a revoked claim would otherwise be unreachable forever.
 * Un-revoking belongs exactly here — an admin typing an email into a form —
 * and nowhere near a game client retrying a download (§9).
 */
class GrantPackEntitlement
{
    public function __construct(private readonly Entitlements $entitlements) {}

    /**
     * @param  string  $source  One of `Entitlement::SOURCES`; `promo` and
     *                          `gift` are what this endpoint is for.
     */
    public function handle(string $email, string $slug, string $source = Entitlement::SOURCE_PROMO): Entitlement
    {
        /** @var User|null $user */
        $user = User::query()->where('email', $email)->first();

        if ($user === null) {
            throw new ApiException(
                'USER_NOT_FOUND',
                __('No account has that email address.'),
                Response::HTTP_NOT_FOUND,
            );
        }

        /** @var Pack|null $pack */
        $pack = Pack::query()->where('slug', $slug)->first();

        if ($pack === null) {
            throw new ApiException(
                'PACK_NOT_FOUND',
                __('No pack has that slug.'),
                Response::HTTP_NOT_FOUND,
            );
        }

        // Always an *account* owner: an admin grants to a household, never to
        // an anonymous device, which has no email to be addressed by (BL-52).
        return $this->entitlements->regrant(EntitlementOwner::forUser($user), $pack, $source);
    }
}
