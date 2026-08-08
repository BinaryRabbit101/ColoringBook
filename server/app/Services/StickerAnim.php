<?php

namespace App\Services;

/**
 * The animation metadata an animated sticker carries (BL-38).
 *
 * **This is a fixed game-facing contract.** An animated sticker is a
 * sprite-sheet PNG plus exactly this object on its manifest entry:
 *
 * ```json
 * "anim": { "hframes": 4, "vframes": 2, "frames": 8, "fps": 12 }
 * ```
 *
 * - `hframes` / `vframes` — the sheet's grid, columns then rows.
 * - `frames` — how many cells are actually drawn, read row-major from the top
 *   left. It is ≤ `hframes * vframes`, which is what lets a 7-frame animation
 *   live on a 4×2 sheet with one blank cell instead of forcing the artist to
 *   pad the sheet to a rectangle they did not draw.
 * - `fps` — playback rate, 1–30.
 *
 * A **static** sticker has no `anim` key at all — not `null`, not an empty
 * object. That absence is the entire back-compatibility story: every sticker
 * published before BL-38 is static and every one of them says so by saying
 * nothing, and a client that has never heard of animation reads the sheet as a
 * still image only if it never looks for the key.
 *
 * This class is the one place that turns loose input (a form body, a JSON
 * object off a manifest) into that shape, so the admin door, the publisher and
 * the validator cannot disagree about what an animation is.
 */
final class StickerAnim
{
    /** The four keys, in the order the manifest writes them. */
    public const KEYS = ['hframes', 'vframes', 'frames', 'fps'];

    /** Sane playback bounds. Below 1 nothing moves; above 30 nothing is seen. */
    public const MIN_FPS = 1;

    public const MAX_FPS = 30;

    /** A grid ceiling, so a typo cannot ask for a million-cell sheet. */
    public const MAX_GRID = 64;

    /**
     * Read `$raw` as the contract above, or `null` when it is not one.
     *
     * Deliberately total: it never throws and never half-fills. A body missing
     * one of the four is not "a partly animated sticker", it is a static one,
     * and `FormRequest` rules are what tell the operator they left a field
     * empty.
     *
     * @return array{hframes: int, vframes: int, frames: int, fps: float}|null
     */
    public static function normalise(mixed $raw): ?array
    {
        if (! is_array($raw)) {
            return null;
        }

        foreach (self::KEYS as $key) {
            $value = $raw[$key] ?? null;

            if ($value === null || $value === '' || ! is_numeric($value)) {
                return null;
            }
        }

        $hframes = (int) $raw['hframes'];
        $vframes = (int) $raw['vframes'];
        $frames = (int) $raw['frames'];
        $fps = (float) $raw['fps'];

        if ($hframes < 1 || $vframes < 1 || $frames < 1 || $fps <= 0) {
            return null;
        }

        return [
            'hframes' => $hframes,
            'vframes' => $vframes,
            'frames' => $frames,
            // A float, because 7.5 fps is a legitimate answer to "twice as slow
            // as 15" and an integer column would silently make it 7.
            'fps' => $fps,
        ];
    }

    /**
     * The animation on a manifest sticker entry, or null when it is static.
     *
     * @param  array<string, mixed>  $sticker
     * @return array{hframes: int, vframes: int, frames: int, fps: float}|null
     */
    public static function of(array $sticker): ?array
    {
        return self::normalise($sticker['anim'] ?? null);
    }
}
