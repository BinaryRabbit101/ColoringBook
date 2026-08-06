<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * One row per install that has ever signed in. `device_uid` is generated
     * by the client and persisted in `user://` — it is the name of that
     * device's Sanctum token, which is how the parent dashboard revokes a
     * single device without touching the others (DLC_SERVER.md §4.2).
     */
    public function up(): void
    {
        Schema::create('devices', function (Blueprint $table) {
            $table->id();
            $table->ulid('ulid')->unique();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            $table->string('device_uid');
            $table->string('device_name')->nullable();
            $table->string('platform')->nullable();
            $table->timestamp('last_seen_at')->nullable();
            $table->timestamps();

            $table->unique(['user_id', 'device_uid']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('devices');
    }
};
