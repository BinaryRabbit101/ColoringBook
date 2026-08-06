<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * One page of a book, and the artifacts it is made of (DLC_SERVER.md §5).
     *
     * Three of the four asset columns are mandatory and travel in the pack:
     * the display art the child sees, the ID map that makes the region lock
     * possible, and the regions JSON the client indexes it with.
     *
     * `mask_asset_id` is **nullable and never shipped** (BL-9 / BL-12,
     * clarified 2026-08-06): the outline mask exists only as a source for the
     * mapping pipeline, and it is optional — when a page has no mask, its
     * display image was the mapping source. The server keeps the mask when
     * one was supplied so a page can be regenerated against an improved
     * pipeline without chasing the artist (§10.1).
     */
    public function up(): void
    {
        Schema::create('pages', function (Blueprint $table) {
            $table->id();
            $table->foreignId('book_id')->constrained()->cascadeOnDelete();
            $table->unsignedInteger('page_index');
            $table->string('title')->nullable();
            $table->foreignId('display_asset_id')->constrained('assets');
            $table->foreignId('mask_asset_id')->nullable()->constrained('assets')->nullOnDelete();
            $table->foreignId('idmap_asset_id')->constrained('assets');
            $table->foreignId('regions_asset_id')->constrained('assets');
            $table->unsignedInteger('image_w');
            $table->unsignedInteger('image_h');
            $table->unsignedInteger('region_count');
            $table->timestamps();

            $table->unique(['book_id', 'page_index']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('pages');
    }
};
