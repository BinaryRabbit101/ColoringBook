<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * The authoring workspace for a sticker set built in the browser (BL-37).
 *
 * Exactly the shape BL-24 gave books, and for exactly the same reason: the
 * catalog's `sticker_sets` table is a projection of the newest release and is
 * dropped and rebuilt on every publish, so it can hold no draft state. This is
 * what the publish button builds a §7.2 pack directory *from*.
 *
 * One authored set ↔ one pack, `packs.slug = set_uid`, `packs.kind =
 * 'sticker_set'`. Packs stay the delivery and entitlement unit — the game
 * client's download path did not move an inch for BL-37 — while the operator
 * thinks in sticker sets.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('authored_sticker_sets', function (Blueprint $table): void {
            $table->id();
            $table->ulid('ulid')->unique();

            // Authored once, stable forever, never derived. Unique here as well
            // as in `sticker_sets`, so two drafts cannot race for one uid.
            $table->string('set_uid')->unique();

            $table->foreignId('pack_id')->constrained()->cascadeOnDelete();

            $table->string('title');
            $table->string('blurb', 500)->nullable();

            // Where the set sits in the client's cycle ring (BL-36), low first.
            $table->unsignedInteger('sort_order')->default(100);

            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('authored_sticker_sets');
    }
};
