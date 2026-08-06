<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Who owns what (DLC_SERVER.md §5 "Entitlements", §9).
     *
     * The server is the entitlement *authority*: the client caches this list
     * for offline play but never decides what it owns, and every download is
     * authorised against a row here (§9).
     *
     * One row per (user, pack) — owning a pack is not a quantity. `source`
     * records how it was acquired; WP3 only ever writes `free` (the implicit
     * grant on first download of a free pack) and `promo`/`admin` (WP5's
     * grant-by-email). `purchase` + the `platform*` columns are Phase 6.
     *
     * `revoked_at` — a refund or an admin take-back — is deliberately *not* a
     * delete: it hides the books from the shelf while the pixels a child
     * already painted stay on disk (§7.3). A revoked free pack stays revoked;
     * the auto-grant never resurrects it.
     */
    public function up(): void
    {
        Schema::create('entitlements', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            $table->foreignId('pack_id')->constrained()->cascadeOnDelete();
            $table->string('source'); // purchase|promo|free|gift|admin
            $table->string('platform')->nullable(); // google|apple|stripe|null
            $table->string('platform_txn_id')->nullable();
            $table->timestamp('granted_at');
            $table->timestamp('revoked_at')->nullable();
            $table->timestamps();

            $table->unique(['user_id', 'pack_id']);
            // A store transaction may only ever be redeemed once. SQLite (and
            // MySQL) treat NULLs as distinct here, so the whole of WP3 — where
            // both columns are null — is unaffected.
            $table->unique(['platform', 'platform_txn_id']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('entitlements');
    }
};
