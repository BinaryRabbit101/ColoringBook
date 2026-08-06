<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * One row per (account, child, book) — DLC_SERVER.md §5 "Saves".
     *
     * Per-book rather than one blob per account is what removes most conflicts:
     * two devices colouring different books never contend. `revision` is the
     * per-row integer the `PUT /sync/progress` optimistic-concurrency check
     * turns on.
     *
     * There is no `ulid` column here on purpose. The house rule is that every
     * row crossing the API boundary carries a ULID *and is addressed by it* —
     * this row is addressed by its authored `book_uid` instead, which
     * server/CLAUDE.md names as the one documented exception (design §6.1).
     */
    public function up(): void
    {
        Schema::create('book_progress', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            // Null means account-level progress: an account that never made
            // any child profiles still syncs its shelf.
            $table->foreignId('child_profile_id')->nullable()->constrained()->cascadeOnDelete();

            // Authored, stable forever, never derived from a res:// path (§6.1).
            $table->string('book_uid', 64);

            $table->unsignedInteger('revision')->default(1);
            $table->unsignedInteger('current_page_index')->default(0);
            // ["complete", "in_progress", "untouched", ...] — index = page.
            $table->json('page_statuses');
            $table->unsignedInteger('furthest_page_index')->default(0);

            // The client's clock at the moment it wrote the save. Drives the
            // merge's current_page_index tie-break (§6.3), and is clamped on
            // the way in, so it can never be wildly in the future.
            $table->timestamp('client_updated_at');

            // Microsecond precision: `updated_at` is the `since` cursor, and
            // at whole-second resolution a row written later in the same
            // second as the cursor would be invisible to the next pull.
            $table->timestamps(6);

            // UNIQUE(user_id, child_profile_id, book_uid) — except SQLite (and
            // every other engine) treats NULLs as distinct, so a null
            // child_profile_id would let the same book be inserted twice.
            // Indexing a stored generated column that folds NULL to 0 gives
            // the constraint the design actually asks for.
            $table->unsignedBigInteger('profile_key')->storedAs('coalesce(child_profile_id, 0)');
            $table->unique(['user_id', 'profile_key', 'book_uid']);

            $table->index('updated_at');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('book_progress');
    }
};
