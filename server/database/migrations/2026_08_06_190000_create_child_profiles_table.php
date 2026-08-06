<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * A child profile is a nickname and an avatar index. That is the entire
     * record of the child (DLC_SERVER.md §4.1) — the design doc's `age_band`
     * column is deliberately omitted (SERVER_BUILD_PLAN.md, Q12).
     */
    public function up(): void
    {
        Schema::create('child_profiles', function (Blueprint $table) {
            $table->id();
            $table->ulid('ulid')->unique();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            $table->string('nickname');
            $table->unsignedSmallInteger('avatar_index')->default(0);
            // 'child' | 'adult' — the default palette/difficulty the game
            // opens this profile in. Stored as a string: SQLite has no enum
            // and adding a mode later must not need a table rebuild.
            $table->string('default_mode')->default('child');
            $table->timestamps();

            $table->index('user_id');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('child_profiles');
    }
};
