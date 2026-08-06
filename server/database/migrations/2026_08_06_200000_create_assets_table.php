<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Content-addressed originals — every byte a page is made of
     * (DLC_SERVER.md §5 "Catalog & content").
     *
     * `storage_path` is always `<sha256[0:2]>/<sha256>` on the `assets` disk,
     * so identical art uploaded twice costs one copy and a checksum mismatch
     * is detectable without a database round trip (§5 "Storage layout").
     *
     * `kind = 'mask'` rows are stored but never shipped: per BL-9 the outline
     * mask exists only to generate the ID map, and it is optional per page —
     * a page with no mask was mapped from its display image (§7.2).
     */
    public function up(): void
    {
        Schema::create('assets', function (Blueprint $table) {
            $table->id();
            $table->ulid('ulid')->unique();
            $table->string('kind'); // display|mask|idmap|regions|cover
            $table->string('storage_path');
            $table->unsignedBigInteger('bytes');
            $table->string('sha256', 64);
            $table->string('mime');
            $table->unsignedInteger('width')->nullable();
            $table->unsignedInteger('height')->nullable();
            $table->timestamps();

            // Content addressing is per-sha, but the same bytes can legitimately
            // play two roles (a page's display image doubling as a book cover),
            // and `kind` drives validation — so the pair is what's unique.
            $table->unique(['sha256', 'kind']);
            $table->index('sha256');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('assets');
    }
};
