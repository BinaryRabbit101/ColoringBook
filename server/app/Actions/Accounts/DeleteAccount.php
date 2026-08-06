<?php

namespace App\Actions\Accounts;

use App\Models\BookProgress;
use App\Models\ChildProfile;
use App\Models\Device;
use App\Models\PaintLayer;
use App\Models\User;
use App\Services\PaintStorage;
use Illuminate\Support\Facades\DB;

/**
 * Delete the account, for real.
 *
 * "Account deletion must be self-serve and must actually delete (progress
 * rows, paint blobs, profiles), not soft-delete" — DLC_SERVER.md §4.1. There
 * is no `deleted_at` anywhere in this schema and there never will be.
 *
 * Child profiles, devices, book progress and paint layers cascade through
 * their foreign keys; Sanctum's tokens are polymorphic with no FK of their
 * own, so they are deleted here explicitly. The **blobs** are swept after the
 * transaction commits: a disk is not part of the FK graph and cannot be rolled
 * back, so deleting the pictures before the rows are certainly gone would risk
 * an account that still exists with its colouring missing.
 */
class DeleteAccount
{
    public function __construct(private readonly PaintStorage $paint) {}

    public function handle(User $user): void
    {
        DB::transaction(function () use ($user): void {
            // Polymorphic: no database-level cascade to lean on.
            $user->tokens()->delete();

            // Explicit rather than FK-only, so deletion is correct even on a
            // connection with foreign keys switched off. Paint first: its rows
            // hang off book_progress.
            PaintLayer::query()
                ->whereIn('book_progress_id', BookProgress::query()->select('id')->where('user_id', $user->id))
                ->delete();

            BookProgress::query()->where('user_id', $user->id)->delete();
            ChildProfile::query()->where('user_id', $user->id)->delete();
            Device::query()->where('user_id', $user->id)->delete();

            $user->delete();
        });

        // Everything under paint/<user_ulid>/ — the account's own shelf and
        // every child's.
        $this->paint->forgetUser($user);
    }
}
