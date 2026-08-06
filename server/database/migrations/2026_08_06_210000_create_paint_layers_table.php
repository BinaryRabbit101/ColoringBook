<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * One row per painted page — DLC_SERVER.md §5 "Saves", §6.3.
     *
     * The row is the *current* picture for that page and nothing else: there
     * is exactly one per `(book_progress, page_index)`, and a write that wins
     * last-write-wins overwrites it in place. The version it displaced is not
     * lost — it moves to `retained_paint_layers`, which is the "restore the
     * older picture" safety net.
     *
     * Hanging off `book_progress` rather than off the user is what makes the
     * shelf boundary automatic: the account-level shelf and each child's shelf
     * are separate `book_progress` rows, so they cannot see each other's paint,
     * and deleting either takes its pictures with it.
     */
    public function up(): void
    {
        Schema::create('paint_layers', function (Blueprint $table) {
            $table->id();

            // The house rule: anything addressed across the API boundary
            // carries a ULID. Here it is what the signed blob URL names, so a
            // download link never exposes a guessable sequential id.
            $table->ulid('ulid')->unique();

            $table->foreignId('book_progress_id')->constrained('book_progress')->cascadeOnDelete();

            // 0-based, exactly like `page_statuses` and `current_page_index`.
            // The *file* is 1-based (`page_01.png`), matching what the client
            // already writes to `user://paint/<slug>/` (game_state.gd).
            $table->unsignedInteger('page_index');

            $table->char('sha256', 64);
            $table->unsignedInteger('bytes');

            // Relative to the `paint` disk: <user_ulid>/[<profile_ulid>/]<book_uid>/page_NN.png
            $table->string('storage_path');

            // Bumped on every winning write. Also names the retained file of
            // the version this one displaced (page_NN.<revision>.png).
            $table->unsignedInteger('revision')->default(1);

            // The device's clock when the child stopped painting. The whole
            // LWW decision turns on this one column (§6.3).
            $table->timestamp('client_painted_at', 6);

            $table->timestamps(6);

            $table->unique(['book_progress_id', 'page_index']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('paint_layers');
    }
};
