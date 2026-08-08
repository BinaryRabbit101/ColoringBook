<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * The shelf-level erase clock — BL-18, DLC_SERVER.md §6.3 "Erasure".
     *
     * "Erase all progress" used to be an *absence*, and an absence always
     * loses the §6.3 merge: the rule only ever climbs, so the next pull put
     * everything back and the button looked broken. The fix is to make an
     * erasure a **state** — one instant, per shelf, that every earlier state
     * is measured against. Rows on the shelf are then really deleted, and this
     * row is the thing that stops them coming back.
     *
     * A shelf is `(user, child_profile|null)`, exactly as `book_progress` keys
     * it, so the same `profile_key` trick applies: SQL treats two NULLs as
     * distinct, and without the stored generated column the account-level
     * shelf would not be constrained to one row at all.
     *
     * **A table rather than a column on `users`/`child_profiles`** for one
     * concrete reason: the censor is a `<=` against `client_updated_at`, so
     * the clock has to keep its microseconds, and microsecond storage on an
     * Eloquent model is a `$dateFormat` on the *whole* model. Putting the
     * clock on `users` would silently restamp every other timestamp on the
     * account. Here it is the only column, and it can be as precise as the
     * comparison needs.
     *
     * A missing row means "this shelf has never been erased", which is not the
     * same as the epoch — the epoch would censor a state whose clock is wrong
     * in the other direction.
     */
    public function up(): void
    {
        Schema::create('shelf_erasures', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            // Null is the account-level shelf, the one the game syncs to when
            // nobody has made a child profile.
            $table->foreignId('child_profile_id')->nullable()->constrained()->cascadeOnDelete();

            // Monotonic: a wipe only ever moves it forward (the merge takes
            // the later of the two), so replaying an old erase is a no-op.
            $table->timestamp('erased_at', 6);

            $table->timestamps(6);

            $table->unsignedBigInteger('profile_key')->storedAs('coalesce(child_profile_id, 0)');
            $table->unique(['user_id', 'profile_key']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('shelf_erasures');
    }
};
