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
     * for offline play but never decides what it owns, and every paid download
     * is authorised against a row here (§9).
     *
     * **The owner is a device.** There are no accounts: one row per
     * (device, pack), and owning a pack is not a quantity. `source` records how
     * it was acquired — `free` (the implicit grant on first download of a free
     * pack), `purchase` (a verified store receipt), and `promo`/`gift`/`admin`
     * (the operator's grant desk).
     *
     * `revoked_at` — a refund or an admin take-back — is deliberately *not* a
     * delete: it hides the books from the shelf while the pixels a child
     * already painted stay on the tablet (§7.3). A revoked free pack stays
     * revoked; the auto-grant never resurrects it.
     *
     * ## Receipt uniqueness is **per device**, on purpose
     *
     * `UNIQUE(device_id, platform, platform_txn_id)` rather than a global
     * `UNIQUE(platform, platform_txn_id)`. Play Billing and StoreKit hand the
     * same purchase token to every device signed into the same store account,
     * and each of them legitimately earns its own row — that is the entire
     * "restore purchases" mechanism, and Google Play *requires* non-consumables
     * to be restorable. Within one device it is still once-only, so a replayed
     * receipt cannot mint a second row. SQL treats NULLs as distinct, so rows
     * with no platform (free/promo grants) are unaffected either way.
     */
    public function up(): void
    {
        Schema::create('entitlements', function (Blueprint $table) {
            $table->id();
            $table->foreignId('device_id')->constrained()->cascadeOnDelete();
            $table->foreignId('pack_id')->constrained()->cascadeOnDelete();
            $table->string('source'); // purchase|promo|free|gift|admin
            $table->string('platform')->nullable(); // google|apple|stripe|null
            $table->string('platform_txn_id')->nullable();
            $table->timestamp('granted_at');
            $table->timestamp('revoked_at')->nullable();
            $table->timestamps();

            $table->unique(['device_id', 'pack_id']);
            $table->unique(['device_id', 'platform', 'platform_txn_id']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('entitlements');
    }
};
