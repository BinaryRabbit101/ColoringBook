<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * A sticker set inside a pack (BL-37, DLC_SERVER.md §5) — the sticker half of
 * `books`, and the same kind of table: a **projection of the newest published
 * release**, dropped and rebuilt by `PublishPackDirectory` on every publish.
 * Draft state lives in `authored_sticker_sets`.
 *
 * `set_uid` is load-bearing exactly the way `book_uid` is (§6.1): a saved
 * sticker placement in a child's save names it, so it is authored once, globally
 * unique and stable forever. Reusing one across packs would make two different
 * sets fight over one strip position on every device.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('sticker_sets', function (Blueprint $table): void {
            $table->id();
            $table->ulid('ulid')->unique();
            $table->foreignId('pack_id')->constrained()->cascadeOnDelete();
            $table->string('set_uid')->unique();
            $table->string('title');
            $table->foreignId('cover_asset_id')->nullable()->constrained('assets')->nullOnDelete();
            $table->unsignedInteger('sort_order')->default(0);
            $table->timestamps();

            $table->index(['pack_id', 'sort_order']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('sticker_sets');
    }
};
