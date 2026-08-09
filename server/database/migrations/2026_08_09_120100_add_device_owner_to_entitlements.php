<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Entitlements grow a second kind of owner (BL-52, DLC_SERVER.md §4.3, §9).
     *
     * A pack is now owned by **exactly one** of an account or an anonymous
     * device. `user_id` becomes nullable, `device_id` appears beside it, and
     * `owner_key` — `'u<id>'` or `'d<id>'`, the `profile_key` trick with a
     * discriminator on the front — carries the two uniqueness rules the design
     * asks for:
     *
     *   UNIQUE(owner_key, pack_id)                    one claim per owner per pack
     *   UNIQUE(owner_key, platform, platform_txn_id)  a purchase redeems once *per owner*
     *
     * The second is a deliberate **relaxation** of the old
     * `UNIQUE(platform, platform_txn_id)`. Play Billing hands the same purchase
     * token to every device signed into the same store account, and each of
     * them legitimately earns its own row — that is the whole "bought once,
     * owned everywhere" mechanism (§4.3). Within one owner it is still
     * once-only, so a replayed receipt cannot mint a second row.
     *
     * `virtualAs` for the same reason the devices migration gives: SQLite
     * cannot `ALTER TABLE ADD COLUMN` a STORED generated column.
     *
     * The "exactly one owner" invariant is enforced in PHP
     * (`App\Services\EntitlementOwner`) rather than by a CHECK constraint,
     * because SQLite cannot add one to an existing table either. A row with
     * neither owner gets a NULL `owner_key` and so is constrained by nothing —
     * which is exactly why nothing is allowed to write one.
     */
    public function up(): void
    {
        Schema::table('entitlements', function (Blueprint $table) {
            $table->foreignId('user_id')->nullable()->change();
        });

        Schema::table('entitlements', function (Blueprint $table) {
            $table->dropUnique(['user_id', 'pack_id']);
            $table->dropUnique(['platform', 'platform_txn_id']);
        });

        Schema::table('entitlements', function (Blueprint $table) {
            $table->foreignId('device_id')->nullable()->after('user_id')
                ->constrained()->cascadeOnDelete();
        });

        Schema::table('entitlements', function (Blueprint $table) {
            $table->string('owner_key')->nullable()
                ->virtualAs("coalesce('u' || user_id, 'd' || device_id)");

            $table->unique(['owner_key', 'pack_id']);
            $table->unique(['owner_key', 'platform', 'platform_txn_id']);
        });
    }

    public function down(): void
    {
        Schema::table('entitlements', function (Blueprint $table) {
            $table->dropUnique(['owner_key', 'pack_id']);
            $table->dropUnique(['owner_key', 'platform', 'platform_txn_id']);
            $table->dropColumn('owner_key');
        });

        Schema::table('entitlements', function (Blueprint $table) {
            $table->dropForeign(['device_id']);
            $table->dropColumn('device_id');
        });

        Schema::table('entitlements', function (Blueprint $table) {
            $table->unique(['user_id', 'pack_id']);
            $table->unique(['platform', 'platform_txn_id']);
        });

        Schema::table('entitlements', function (Blueprint $table) {
            $table->foreignId('user_id')->nullable(false)->change();
        });
    }
};
