<?php

namespace App\Actions\Accounts;

use App\Models\Device;
use App\Models\Entitlement;
use App\Models\User;
use Illuminate\Database\QueryException;

/**
 * Linking is adoption (BL-52, DLC_SERVER.md §4.3).
 *
 * `POST /auth/token` already carries the `device_uid`. When that uid has an
 * anonymous row, signing in folds it into the account and then removes it: the
 * packs the tablet bought before anybody made an account become the household's
 * packs, and the tier the device was on disappears rather than lingering as a
 * second inventory nobody can see.
 *
 * **Union, and the account's row always wins.** A pack the user already has a
 * row for keeps that row exactly as it is — including a *revoked* one, which is
 * the case that matters: a refunded or admin-withdrawn claim must not come back
 * because somebody signed in on a tablet that still remembers owning it.
 * Everything else moves across, keeping its `source`, `platform`,
 * `platform_txn_id` and `granted_at`, so a purchase stays auditable as the same
 * row it always was.
 *
 * **Idempotent.** A second sign-in finds no anonymous row and does nothing. It
 * runs inside `IssueDeviceToken`'s transaction, and the (owner, pack) unique
 * index catches the two-tablets-at-once case: losing that race means the
 * account already has the pack, which is the outcome adoption wanted.
 */
class AdoptAnonymousDevice
{
    /**
     * @return int how many claims moved — for the caller's logs and the tests
     */
    public function handle(User $user, string $deviceUid): int
    {
        $anonymous = Device::query()->anonymous()->where('device_uid', $deviceUid)->first();

        if ($anonymous === null) {
            return 0;
        }

        $moved = $this->migrateEntitlements($user, $anonymous);

        // The anonymous identity ends here: its tokens stop working and its row
        // goes. Any claim still hanging off it was a duplicate of one the
        // account already holds, and cascades away with it.
        $anonymous->tokens()->delete();
        $anonymous->delete();

        return $moved;
    }

    private function migrateEntitlements(User $user, Device $anonymous): int
    {
        $held = Entitlement::query()
            ->where('user_id', $user->id)
            ->pluck('pack_id')
            ->all();

        $moved = 0;

        /** @var iterable<int, Entitlement> $claims */
        $claims = $anonymous->entitlements()->get();

        foreach ($claims as $claim) {
            // Revoked or live, a row the account already has is the truth.
            if (in_array($claim->pack_id, $held, true)) {
                continue;
            }

            $claim->user_id = $user->id;
            $claim->device_id = null;

            try {
                $claim->save();
            } catch (QueryException) {
                // Another sign-in got there first. The account has the pack,
                // which is all adoption was for.
                continue;
            }

            $held[] = $claim->pack_id;
            $moved++;
        }

        return $moved;
    }
}
