<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * One install of the game — **and the only client identity there is**
     * (DLC_SERVER.md §4.3, as amended by the device-only refactor).
     *
     * `device_uid` is minted by the client and persisted in `user://`. It is
     * globally unique here: there are no accounts left for a uid to be scoped
     * to, so `POST /api/v1/device/register` find-or-creates exactly this row
     * and the uid is the whole lookup.
     *
     * The uid is also the **name** of that device's Sanctum token, which is the
     * revocation story: deleting the tokens named `device_uid` signs out
     * exactly one install. The token is minted **on this row** (the model
     * carries `HasApiTokens` + `Authenticatable`), so `$request->user()` is a
     * `Device` on every game route.
     */
    public function up(): void
    {
        Schema::create('devices', function (Blueprint $table) {
            $table->id();
            $table->ulid('ulid')->unique();
            $table->string('device_uid')->unique();
            $table->string('device_name')->nullable();
            $table->string('platform')->nullable();
            $table->timestamp('last_seen_at')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('devices');
    }
};
