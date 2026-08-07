<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * What KIND of content a pack carries (BL-37, DLC_SERVER.md §5, §7.2).
 *
 * Until BL-37 every pack was a colouring book, and the manifest said so by
 * having a `books[]` array. Sticker sets are catalog content delivered by the
 * exact same machinery — same zip, same manifest, same entitlement, same delta
 * update — so the one thing that had to become explicit is which shape the
 * manifest's payload is in.
 *
 * `book` is the default and every existing row gets it, so nothing about the
 * catalog, the download routes or an installed client moves. Delta updates in
 * particular are untouched: they diff the manifest's per-file sha256 map and
 * have never cared what the files are (§7.4, BL-26).
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('packs', function (Blueprint $table): void {
            $table->string('kind')->default('book')->after('slug');
        });
    }

    public function down(): void
    {
        Schema::table('packs', function (Blueprint $table): void {
            $table->dropColumn('kind');
        });
    }
};
