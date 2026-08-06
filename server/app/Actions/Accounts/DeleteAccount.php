<?php

namespace App\Actions\Accounts;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\Device;
use App\Models\User;
use Illuminate\Support\Facades\DB;

/**
 * Delete the account, for real.
 *
 * "Account deletion must be self-serve and must actually delete (progress
 * rows, paint blobs, profiles), not soft-delete" — DLC_SERVER.md §4.1. There
 * is no `deleted_at` anywhere in this schema and there never will be.
 *
 * Child profiles, devices and book progress cascade through their foreign
 * keys; Sanctum's tokens are polymorphic with no FK of their own, so they are
 * deleted here explicitly. WP4 hangs paint off the same cascade — its FK must
 * be declared `cascadeOnDelete`, and any on-disk paint blobs have to be swept
 * here too.
 */
class DeleteAccount
{
    public function handle(User $user): void
    {
        DB::transaction(function () use ($user): void {
            // Polymorphic: no database-level cascade to lean on.
            $user->tokens()->delete();

            // Explicit rather than FK-only, so deletion is correct even on a
            // connection with foreign keys switched off.
            BookProgress::query()->where('user_id', $user->id)->delete();
            ChildProfile::query()->where('user_id', $user->id)->delete();
            Device::query()->where('user_id', $user->id)->delete();

            $user->delete();
        });
    }
}
