<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * The authoring workspace for a book built in the browser (BL-24, §10.3).
 *
 * It is deliberately **not** `books`. That table is a projection of the newest
 * published release — `PublishPackDirectory` drops and rebuilds it on every
 * publish — so it can hold no draft state at all: a page uploaded but not yet
 * mapped, a title changed since the last release, a per-page tuning override.
 * This table is the source the publish step *builds from*, and `books`/`pages`
 * stay exactly what they were: what the last release shipped.
 *
 * One authored book ↔ one pack, slug = `book_uid`. Packs remain the delivery
 * and entitlement unit and the game client changes not at all, while the
 * operator thinks in books.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('authored_books', function (Blueprint $table): void {
            $table->id();
            $table->ulid('ulid')->unique();

            // Authored once, stable forever, never derived (§6.1). Unique here
            // as well as in `books`, so two drafts cannot race for one uid.
            $table->string('book_uid')->unique();

            // The one-book pack this publishes into. Cascade because a pack
            // with no released version is deleted outright with its book; a
            // published pack is retired instead and its workspace goes with it.
            $table->foreignId('pack_id')->constrained()->cascadeOnDelete();

            $table->string('title');
            $table->string('blurb', 500)->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('authored_books');
    }
};
