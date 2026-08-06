<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * One immutable release of a pack (DLC_SERVER.md §7.3).
     *
     * `version` is a monotonic integer per pack, not semver: content has no
     * API surface to be compatible with. Published versions are **immutable**
     * — fixing a typo means publishing the next integer, never rewriting a
     * row. The server, not the manifest, assigns the number.
     *
     * `manifest` is the §7.2 document exactly as shipped inside the zip,
     * including the per-file `{bytes, sha256}` map that makes delta updates
     * possible. It is the authority for what `/packs/{slug}/files/{path}` is
     * willing to serve.
     *
     * `min_client_version` keeps a pack that needs a newer game build
     * invisible to older ones instead of crashing them (§7.3).
     */
    public function up(): void
    {
        Schema::create('pack_versions', function (Blueprint $table) {
            $table->id();
            $table->foreignId('pack_id')->constrained()->cascadeOnDelete();
            $table->unsignedInteger('version');
            $table->json('manifest');
            $table->string('archive_path');
            $table->unsignedBigInteger('archive_bytes');
            $table->string('archive_sha256', 64);
            $table->string('min_client_version')->nullable();
            $table->timestamp('published_at')->nullable();
            $table->timestamps();

            $table->unique(['pack_id', 'version']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('pack_versions');
    }
};
