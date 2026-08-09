<?php

namespace App\Actions\Admin;

use App\Exceptions\ApiException;
use App\Models\Device;
use App\Models\Entitlement;
use App\Models\Pack;
use App\Services\Entitlements;
use Symfony\Component\HttpFoundation\Response;

/**
 * `POST /admin/entitlements` — hand a device a pack (DLC_SERVER.md §11).
 *
 * The support desk's "we're sorry, here" button, and the only way a paid pack
 * reaches a player without a store receipt.
 *
 * It addresses the device by its **`device_uid`**, because that is the only
 * identifier a player can read off their own screen and paste into a support
 * email. There is no account and no email address to address instead — the
 * device is the identity.
 *
 * It is a *re-*grant, deliberately: `Entitlements::grant()` refuses to touch an
 * existing row, so a revoked claim would otherwise be unreachable forever.
 * Un-revoking belongs exactly here — an operator typing a uid into a form —
 * and nowhere near a game client retrying a download (§9).
 */
class GrantPackEntitlement
{
    public function __construct(private readonly Entitlements $entitlements) {}

    /**
     * @param  string  $source  One of `Entitlement::SOURCES`; `promo` and
     *                          `gift` are what this endpoint is for.
     */
    public function handle(string $deviceUid, string $slug, string $source = Entitlement::SOURCE_PROMO): Entitlement
    {
        /** @var Device|null $device */
        $device = Device::query()->where('device_uid', $deviceUid)->first();

        if ($device === null) {
            throw new ApiException(
                'DEVICE_NOT_FOUND',
                __('No device has that id.'),
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

        return $this->entitlements->regrant($device, $pack, $source);
    }
}
