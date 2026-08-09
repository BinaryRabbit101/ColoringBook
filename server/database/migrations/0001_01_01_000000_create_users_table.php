<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * `users` is the **operator** table, and nothing else.
     *
     * There are no player accounts: a game device is its own identity
     * (`devices`, `POST /api/v1/device/register`). The only rows here are the
     * people who sign in to the publishing tool at `/admin/*`, and they are
     * created with `php artisan db:seed` or by hand — there is no registration
     * form and no self-service sign-up anywhere in the application.
     *
     * `is_admin` is still the whole authorisation model (DLC_SERVER.md §10.2):
     * one boolean, no roles, enforced by `App\Http\Middleware\EnsureAdmin`.
     */
    public function up(): void
    {
        Schema::create('users', function (Blueprint $table) {
            $table->id();
            // Public identifier — every row that crosses the API boundary is
            // addressed by its ULID, never by the numeric key (DLC_SERVER.md §5).
            $table->ulid('ulid')->unique();
            $table->string('name')->nullable();
            $table->string('email')->unique();
            $table->timestamp('email_verified_at')->nullable();
            $table->string('password');
            $table->boolean('is_admin')->default(false);
            $table->rememberToken();
            $table->timestamps();
        });

        Schema::create('password_reset_tokens', function (Blueprint $table) {
            $table->string('email')->primary();
            $table->string('token');
            $table->timestamp('created_at')->nullable();
        });

        Schema::create('sessions', function (Blueprint $table) {
            $table->string('id')->primary();
            $table->foreignId('user_id')->nullable()->index();
            $table->string('ip_address', 45)->nullable();
            $table->text('user_agent')->nullable();
            $table->longText('payload');
            $table->integer('last_activity')->index();
        });
    }

    /**
     * Reverse the migrations.
     */
    public function down(): void
    {
        Schema::dropIfExists('users');
        Schema::dropIfExists('password_reset_tokens');
        Schema::dropIfExists('sessions');
    }
};
