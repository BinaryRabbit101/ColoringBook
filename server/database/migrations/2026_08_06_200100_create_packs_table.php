<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * A sellable (or free) bundle of books — the shop row (DLC_SERVER.md §5).
     *
     * `slug` is the public identifier: every §11 catalog route addresses a
     * pack by slug, never by the numeric key or the ULID.
     *
     * `status` is the whole workflow — no roles, no approval chain (§10.2):
     *   draft      invisible to everyone but the admin
     *   published  listed in GET /packs
     *   retired    delisted, but still downloadable by anyone who owns it —
     *              "never delete a pack's files on entitlement loss" (§7.3)
     *
     * The three `sku_*` columns are Phase 6 (payments) and stay null for the
     * whole of this campaign; free and promo entitlements are all WP3 grants.
     */
    public function up(): void
    {
        Schema::create('packs', function (Blueprint $table) {
            $table->id();
            $table->ulid('ulid')->unique();
            $table->string('slug')->unique();
            $table->string('title');
            $table->text('blurb')->nullable();
            $table->string('cover_path')->nullable();
            $table->string('status')->default('draft'); // draft|published|retired
            $table->boolean('is_free')->default(false);
            $table->string('sku_google')->nullable();
            $table->string('sku_apple')->nullable();
            $table->string('sku_stripe')->nullable();
            $table->unsignedInteger('sort_order')->default(0);
            $table->timestamps();

            $table->index(['status', 'sort_order']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('packs');
    }
};
