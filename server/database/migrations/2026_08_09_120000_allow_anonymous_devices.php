<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * The anonymous device tier (BL-52, DLC_SERVER.md §4.3).
     *
     * A device may now exist **without an account**: `POST /device/register`
     * finds-or-creates a `user_id IS NULL` row so a tablet can own packs it
     * bought from the store without anybody typing an email.
     *
     * That breaks the old `UNIQUE(user_id, device_uid)`, because SQL treats
     * two NULLs as distinct — every anonymous registration would insert
     * another row for the same uid. `owner_key = coalesce(user_id, 0)` is the
     * same trick `book_progress.profile_key` plays, and it says both things at
     * once: one row per uid per account, and exactly one anonymous row per uid.
     *
     * `virtualAs`, not `storedAs`: SQLite's `ALTER TABLE ADD COLUMN` refuses a
     * STORED generated column outright (a VIRTUAL one is fine, and indexes over
     * it work identically). `book_progress` could use `storedAs` because it was
     * written that way at CREATE time.
     */
    public function up(): void
    {
        Schema::table('devices', function (Blueprint $table) {
            $table->foreignId('user_id')->nullable()->change();
        });

        Schema::table('devices', function (Blueprint $table) {
            $table->dropUnique(['user_id', 'device_uid']);
        });

        Schema::table('devices', function (Blueprint $table) {
            $table->unsignedBigInteger('owner_key')->virtualAs('coalesce(user_id, 0)');
            $table->unique(['owner_key', 'device_uid']);
        });
    }

    public function down(): void
    {
        Schema::table('devices', function (Blueprint $table) {
            $table->dropUnique(['owner_key', 'device_uid']);
            $table->dropColumn('owner_key');
        });

        Schema::table('devices', function (Blueprint $table) {
            $table->unique(['user_id', 'device_uid']);
        });

        Schema::table('devices', function (Blueprint $table) {
            $table->foreignId('user_id')->nullable(false)->change();
        });
    }
};
