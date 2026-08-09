<?php

namespace App\Concerns;

use App\Services\EntitlementOwner;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * "Whose packs are these?" for every catalog and entitlement controller
 * (BL-52, DLC_SERVER.md §4.3).
 *
 * The rule the design states and this enforces: **gate on abilities, not on
 * the kind of identity**. An account token and an anonymous device token reach
 * exactly the same entitlement surface; what an anonymous device cannot do is
 * decided by the ability it was never issued (`save:sync`), on the sync routes,
 * by the ordinary `abilities:` middleware.
 */
trait ResolvesEntitlementOwner
{
    /**
     * The owner behind this request, or null when nobody is authenticated.
     */
    protected function owner(Request $request): ?EntitlementOwner
    {
        return EntitlementOwner::fromAuthenticatable($request->user());
    }

    /**
     * The owner behind this request, or a 401 in the house error shape.
     */
    protected function requireOwner(Request $request): EntitlementOwner
    {
        $owner = $this->owner($request);

        abort_if($owner === null, Response::HTTP_UNAUTHORIZED);

        return $owner;
    }
}
