<?php

namespace App\Concerns;

use App\Models\Device;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * "Whose packs are these?" for every catalog and entitlement controller.
 *
 * There is exactly one kind of game identity — the `Device` a token was minted
 * on — so this is a type check and nothing more. It stays a helper rather than
 * an inline `instanceof` for two reasons: the 401 has to come out in the house
 * error shape, and Larastan types `$request->user()` from
 * `auth.providers.users.model` (a `User`, i.e. an admin token) and would
 * therefore call the `Device` branch impossible. Hence the `mixed` parameter on
 * `asDevice()` — that is where the real branch lives, and it is deliberate.
 * Don't "fix" it back into an inline instanceof.
 *
 * The rule the routes follow: **gate on abilities, not on the kind of
 * identity**. An admin token carries only `admin` and therefore never gets past
 * these routes' `abilities:` middleware in the first place.
 */
trait ResolvesDevice
{
    /**
     * The device behind this request, or null when nobody is authenticated
     * (or when the bearer is an admin token, which owns no packs).
     */
    protected function device(Request $request): ?Device
    {
        return $this->asDevice($request->user());
    }

    /**
     * The device behind this request, or a 401 in the house error shape.
     */
    protected function requireDevice(Request $request): Device
    {
        $device = $this->device($request);

        abort_if($device === null, Response::HTTP_UNAUTHORIZED);

        return $device;
    }

    private function asDevice(mixed $identity): ?Device
    {
        return $identity instanceof Device ? $identity : null;
    }
}
