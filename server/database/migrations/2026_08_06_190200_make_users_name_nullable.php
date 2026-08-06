<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * The API registration flow (`POST /api/v1/auth/register`) collects an
     * email, a password and a guardian confirmation — nothing else. A name is
     * PII we have no use for, so accounts created from the game have none and
     * the dashboard falls back to the email address (DLC_SERVER.md §4.1).
     *
     * The web register form still asks for one, because a person typing into
     * a browser expects to be greeted by name.
     */
    public function up(): void
    {
        Schema::table('users', function (Blueprint $table) {
            $table->string('name')->nullable()->change();
        });
    }

    public function down(): void
    {
        Schema::table('users', function (Blueprint $table) {
            $table->string('name')->nullable(false)->change();
        });
    }
};
