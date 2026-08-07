<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * The page-level erase clock — BL-18, DLC_SERVER.md §6.3 "Erasure".
     *
     * The shelf clock (see the migration beside this one) answers "erase all
     * progress". This one answers the page's **Start over** button (BL-7),
     * which is the same problem in miniature: the page's paint is deleted and
     * its status put back to `untouched`, and the §6.3 merge — which only ever
     * climbs — used to put `complete` straight back on the next pull.
     *
     * One nullable instant per page, index-parallel to `page_statuses`, so it
     * merges by exactly the same rule the rest of the row does: per element,
     * the later clock wins, and a side whose `client_updated_at` is at or
     * before the winning clock contributes `untouched` for that page. Trailing
     * nulls are trimmed, so a book nobody has reset stores `[]` and costs
     * nothing on the wire.
     *
     * Nullable rather than `default('[]')` so every row written before BL-18
     * reads back as "no page has ever been erased" without a backfill.
     */
    public function up(): void
    {
        Schema::table('book_progress', function (Blueprint $table) {
            $table->json('page_erased_at')->nullable();
        });
    }

    public function down(): void
    {
        Schema::table('book_progress', function (Blueprint $table) {
            $table->dropColumn('page_erased_at');
        });
    }
};
