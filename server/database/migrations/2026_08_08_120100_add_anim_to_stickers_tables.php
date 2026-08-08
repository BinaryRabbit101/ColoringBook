<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Animated stickers (BL-38).
 *
 * An animated sticker is a **sprite-sheet PNG plus four numbers**:
 * `{hframes, vframes, frames, fps}`. It is stored as one nullable JSON column
 * rather than four columns for the reason the manifest carries it as one
 * object: the four are meaningless apart — `frames` without `hframes` cannot be
 * read — and "this sticker is static" has to be exactly one value, not four
 * nulls that some code path might half-fill.
 *
 * **Null is the whole back-compatibility story.** A static sticker has no
 * `anim` key in the manifest, which is what every sticker published before this
 * migration has, and what `StickerSetDef` in the game already reads.
 *
 * Both tables get it: `authored_stickers` is the workspace, `stickers` is the
 * projection of the newest release that `rebuildCatalog()` recreates on every
 * publish.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('authored_stickers', function (Blueprint $table): void {
            $table->json('anim')->nullable()->after('image_h');
        });

        Schema::table('stickers', function (Blueprint $table): void {
            $table->json('anim')->nullable()->after('image_h');
        });
    }

    public function down(): void
    {
        Schema::table('authored_stickers', function (Blueprint $table): void {
            $table->dropColumn('anim');
        });

        Schema::table('stickers', function (Blueprint $table): void {
            $table->dropColumn('anim');
        });
    }
};
