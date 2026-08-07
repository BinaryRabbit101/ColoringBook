<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * One sticker in the authoring workspace (BL-37).
 *
 * Simpler than `authored_pages` by exactly the amount §10.3 predicted: there is
 * an upload and there is a verdict, and nothing in between. A sticker has no
 * regions, so there is no mapping job, no queue, no `mapping_status`, and no
 * headless-Godot step — `StickerValidation` looks at the image and that is the
 * whole publish gate.
 *
 * `validation_errors` is nullable rather than defaulted for the same reason the
 * page table's derived columns are: "uploaded, not checked yet" is a real state
 * and pretending otherwise is how a broken image gets published.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('authored_stickers', function (Blueprint $table): void {
            $table->id();
            $table->ulid('ulid')->unique();

            $table->foreignId('authored_sticker_set_id')->constrained()->cascadeOnDelete();

            // 0-based strip position, like every other index on this API (§11).
            $table->unsignedInteger('sticker_index');

            // Stable within the set; a saved placement names (set_uid, sticker_id).
            $table->string('sticker_id');
            $table->string('title')->nullable();

            $table->foreignId('image_asset_id')->constrained('assets');
            $table->unsignedInteger('image_w')->nullable();
            $table->unsignedInteger('image_h')->nullable();

            $table->json('validation_errors')->nullable();
            $table->json('validation_warnings')->nullable();

            $table->timestamps();

            $table->unique(['authored_sticker_set_id', 'sticker_index']);
            $table->unique(['authored_sticker_set_id', 'sticker_id']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('authored_stickers');
    }
};
