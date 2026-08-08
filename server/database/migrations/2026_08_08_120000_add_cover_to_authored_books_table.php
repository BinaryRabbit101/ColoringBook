<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * An artist-supplied cover for a web-authored book (BL-38).
 *
 * Until now a book's cover was page one's display art, chosen by the publisher
 * because a one-book pack had nothing else to be a cover. That is still the
 * fallback and it still ships: this column is **optional**, and when it is null
 * the manifest's `cover` keeps pointing at `page_01.png` exactly as it did, so
 * every pack published before this migration stays valid and the game's own
 * fallback ("no cover ⇒ the first page's detail image") never has to fire for
 * an old pack.
 *
 * `nullOnDelete` rather than a cascade: assets are shared by digest and a
 * published release may be standing on the same bytes, so losing the row must
 * never take the book with it.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('authored_books', function (Blueprint $table): void {
            $table->foreignId('cover_asset_id')
                ->nullable()
                ->after('blurb')
                ->constrained('assets')
                ->nullOnDelete();
        });
    }

    public function down(): void
    {
        Schema::table('authored_books', function (Blueprint $table): void {
            $table->dropConstrainedForeignId('cover_asset_id');
        });
    }
};
