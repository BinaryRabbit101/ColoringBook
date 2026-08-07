<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * A page in the authoring workspace (BL-24, §10.3).
 *
 * The uploads (`display_asset_id`, the optional `mask_asset_id`) are what the
 * operator supplied; everything from `idmap_asset_id` down is what the mapping
 * job produced and what §10.1 made of it. All of the latter is nullable,
 * because "uploaded but not mapped yet" is the normal state of a page for as
 * long as the queue takes.
 *
 * BL-9/BL-12 semantics live in the two mask columns:
 *
 *   - `mask_asset_id` is the artist's original — the **mapping source** when it
 *     is present, kept forever so a page can be re-mapped against an improved
 *     pipeline (§10.1).
 *   - `mask_artifact_asset_id` is the pipeline's display-resolution resample,
 *     and is the one that ships as `page_NN_mask.png` (BL-12).
 *
 * No mask at all is a normal, supported page: the display image is then its own
 * mapping source and no mask file appears in the pack.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('authored_pages', function (Blueprint $table): void {
            $table->id();
            $table->ulid('ulid')->unique();

            $table->foreignId('authored_book_id')->constrained()->cascadeOnDelete();

            // 0-based, exactly like every other page index on the API (§11).
            $table->unsignedInteger('page_index');
            $table->string('title')->nullable();

            $table->foreignId('display_asset_id')->constrained('assets');
            $table->foreignId('mask_asset_id')->nullable()->constrained('assets');

            $table->foreignId('idmap_asset_id')->nullable()->constrained('assets');
            $table->foreignId('regions_asset_id')->nullable()->constrained('assets');
            $table->foreignId('mask_artifact_asset_id')->nullable()->constrained('assets');

            $table->unsignedInteger('image_w')->nullable();
            $table->unsignedInteger('image_h')->nullable();
            $table->unsignedInteger('region_count')->nullable();

            // pending → queued → running → mapped | failed.
            $table->string('mapping_status')->default('pending');
            $table->text('mapping_error')->nullable();
            $table->text('mapping_log')->nullable();
            $table->timestamp('mapped_at')->nullable();

            // The §10.1 verdict, in the operator's language. `mapped` with a
            // non-empty error list is a page that mapped and is still not
            // publishable — a giant region means the art has a gap.
            $table->json('validation_errors')->nullable();
            $table->json('validation_warnings')->nullable();

            // Per-page overrides of coloringbook.authoring.tuning.
            $table->json('tuning')->nullable();

            $table->timestamps();

            $table->unique(['authored_book_id', 'page_index']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('authored_pages');
    }
};
