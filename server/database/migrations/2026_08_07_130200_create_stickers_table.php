<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * One sticker of a published set (BL-37) — `pages` for stickers, and rebuilt on
 * every publish for the same reason.
 *
 * `sticker_id` is unique WITHIN its set, not globally: two sets may both offer a
 * `star`, and a saved placement names the pair. It is still authored and stable,
 * because renaming one orphans every sticker a child has already stuck down.
 *
 * There is no ID map, no regions JSON and no mapping status here. A sticker has
 * no regions, so §10.1's pipeline does not apply and the publish path is
 * strictly simpler than a book's — image validation only.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('stickers', function (Blueprint $table): void {
            $table->id();
            $table->foreignId('sticker_set_id')->constrained()->cascadeOnDelete();
            $table->unsignedInteger('sticker_index');
            $table->string('sticker_id');
            $table->string('title')->nullable();
            $table->foreignId('image_asset_id')->constrained('assets');
            $table->unsignedInteger('image_w')->nullable();
            $table->unsignedInteger('image_h')->nullable();
            $table->timestamps();

            $table->unique(['sticker_set_id', 'sticker_index']);
            $table->unique(['sticker_set_id', 'sticker_id']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('stickers');
    }
};
