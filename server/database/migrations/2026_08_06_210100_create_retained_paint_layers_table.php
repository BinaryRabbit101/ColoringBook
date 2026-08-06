<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * The losing side of a last-write-wins paint upload, kept for 30 days
     * (DLC_SERVER.md §6.3).
     *
     * A sidecar table rather than more rows in `paint_layers`, because
     * `UNIQUE(book_progress_id, page_index)` is the thing that makes "the
     * current picture" unambiguous, and relaxing it to hold history would put
     * every reader in the business of asking which row is live.
     *
     * "This is the cheap answer to the only genuinely upsetting failure mode:
     * a child's finished picture vanishing." One button in the parent
     * dashboard swaps a row here back into `paint_layers`; anything older than
     * `coloringbook.paint.retention_days` is swept by `paint:prune`.
     */
    public function up(): void
    {
        Schema::create('retained_paint_layers', function (Blueprint $table) {
            $table->id();
            $table->ulid('ulid')->unique();

            // Cascades: deleting the page's current layer (or the account, or
            // the child) takes the retained versions with it. The blobs are
            // swept separately — a disk is not part of the FK graph.
            $table->foreignId('paint_layer_id')->constrained()->cascadeOnDelete();

            $table->char('sha256', 64);
            $table->unsignedInteger('bytes');

            // <user_ulid>/[<profile_ulid>/]<book_uid>/page_NN.<revision>.png
            $table->string('storage_path');

            // The revision this version held while it was current. It is also
            // the suffix in the filename above, which is what keeps two
            // retained versions of the same page from colliding.
            $table->unsignedInteger('revision');

            $table->timestamp('client_painted_at', 6);

            // When it *lost* — the clock the 30-day sweep runs against. Not
            // `created_at`, so that a restore can put a version back into
            // retention with a fresh lease rather than one already half spent.
            $table->timestamp('retained_at', 6);

            $table->timestamps(6);

            $table->index('retained_at');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('retained_paint_layers');
    }
};
