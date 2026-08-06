<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * A colouring book inside a pack (DLC_SERVER.md §5).
     *
     * `book_uid` is the load-bearing identifier of the whole system: authored
     * once (e.g. `coyote-2026`), globally unique, stable forever, and never
     * derived from a filename or a `res://` path (§6.1). Every progress row
     * and every paint layer is keyed by it, so reusing one across packs would
     * silently merge two different books' saves — hence the global unique.
     */
    public function up(): void
    {
        Schema::create('books', function (Blueprint $table) {
            $table->id();
            $table->ulid('ulid')->unique();
            $table->foreignId('pack_id')->constrained()->cascadeOnDelete();
            $table->string('book_uid')->unique();
            $table->string('title');
            $table->foreignId('cover_asset_id')->nullable()->constrained('assets')->nullOnDelete();
            $table->unsignedInteger('sort_order')->default(0);
            $table->timestamps();

            $table->index(['pack_id', 'sort_order']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('books');
    }
};
