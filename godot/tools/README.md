# `godot/tools/` — dev-box scripts

Headless GDScript run by a human at a terminal. **Never referenced by a game scene**, never
shipped: everything here reads the project and writes build artifacts.

| Script | What it does |
|---|---|
| `generate_region_map.gd` | line-art PNG → `_idmap.png` + `_regions.json` (+ `_mask.png`). See the `mapping-pipeline` skill. |
| `build_pack.gd` | authored book(s) → a §7.2 DLC **pack directory** for `php artisan pack:publish`. |
| `generate_test_page.gd` | synthetic page art for the test book. |
| `generate_app_icon.gd` | the app icon. |

The Godot binary on this box:

```
c:\Users\binar\OneDrive\Desktop\Godot\Godot_v4.5.1-stable_win64.exe\Godot_v4.5.1-stable_win64.exe
```

---

## `build_pack.gd` — the `pack build` CLI (DLC_SERVER.md §10.2)

Walks `res://resources/books/<book>/book.tres`, resolves every `PageDef` to its shipped
artifacts, and writes the pack layout of DLC_SERVER.md §7.2:

```
<out>/manifest.json                             manifest_version 1, per-file sha256 map
<out>/books/<book_uid>/book.json                the manifest's books[] entry, verbatim
<out>/books/<book_uid>/page_01.png              the DISPLAY image
<out>/books/<book_uid>/page_01_mask.png         ONLY when that page has a mask
<out>/books/<book_uid>/page_01_idmap.png
<out>/books/<book_uid>/page_01_regions.json
```

### Why GDScript rather than a PHP artisan command

The input is a Godot resource graph — `book.tres` holding an ordered `Array[PageDef]`, each
page naming its art by `res://` path. Only the engine reads that authoritatively (import
remaps, the `.res` variant an export can produce, `BookDef.validate()`), and §10.1 already
puts the whole content pipeline on the dev box, next to the artist's originals under
`assets/books/<book>/source/`. A PHP re-implementation of `.tres` parsing would be a second,
silently-diverging definition of what a book is.

It writes a **directory**, not a zip, and does not POST. `pack:publish` (and later
`POST /api/v1/admin/packs/{slug}/versions`) owns the zip, the archive digest and the version
number — §7.3 makes the *server* assign `pack_version`, so `--version` here is advisory and
exists only so the manifest is complete on its own. Adding a `--post <url> --token <t>` mode
later is a small addition to `_report()`; nothing about the output has to change.

### Flags

```
--book <dir>              a book directory. `coyote`, `resources/books/coyote` and
                          `res://resources/books/coyote` all work. Repeatable.
--book-uid <uid>          the AUTHORED, stable-forever uid (§6.1) for the preceding --book.
                          Optional once BookDef carries `book_uid`; required until then.
--out <dir>               output pack directory (absolute OS path).
--slug <slug>             pack_slug — lowercase letters, digits, hyphens.
--title <text>            pack title.
--blurb <text>            optional one-line shop description.
--version <n>             advisory pack_version (default 1).
--min-client-version <v>  default: this project's application/config/version.
--cover <path>            pack cover art; defaults to book 1's cover, already in the pack.
--free | --paid           writes `is_free` into the manifest.
```

It hard-fails (exit 1) on: a book that does not `validate()`, a missing artifact, an ID map
whose dimensions differ from the display image, a regions JSON that is not schema v1 or whose
`image_size` disagrees, or zero regions. Those are the §10.1 checks that are cheap here and
expensive to debug on the server. Exit 2 is bad usage.

An `--out` that already contains a `manifest.json` is **replaced wholesale**, so a page
deleted from a book cannot survive as a stale file. An `--out` that is non-empty and is *not*
a pack directory is refused.

---

## Rebuild + republish the coyote pack

Two commands, from the repo root. The first rebuilds the pack directory from whatever the
artist and the mapping pipeline last produced; the second imports it as the pack's **next**
version (published versions are immutable — §7.3 — so this is the correct way to ship a fix).

```sh
"c:/Users/binar/OneDrive/Desktop/Godot/Godot_v4.5.1-stable_win64.exe/Godot_v4.5.1-stable_win64.exe" \
  --headless --path "c:/Users/binar/Documents/ColoringBook/godot" \
  --script tools/build_pack.gd -- \
    --book resources/books/coyote --book-uid coyote-2026 \
    --slug coyote-book --title "Coyote" \
    --blurb "A coyote at dusk. One page, hand-drawn." \
    --version 1 --free \
    --out "c:/Users/binar/Documents/ColoringBook/build/packs/coyote-book"

cd server && php artisan pack:publish "C:/Users/binar/Documents/ColoringBook/build/packs/coyote-book" --free
```

Notes:

- `build/` at the repo root is a build artifact directory and there is **no root
  `.gitignore`** yet — don't commit it. (`godot/.gitignore` only ignores `godot/build/`, and
  the pack output cannot live there: Godot would import the PNGs into the project.)
- `pack:publish` currently warns *"Masks are source-only and are stored but never
  delivered"*. That wording predates BL-12: the mask **is** listed in `files`, ships in
  `pack.zip` and is served by the delta route. Verified end to end.
- Pixel validation (§10.1) is not run by the CLI — it runs on the admin upload path. To get
  the verdict for a built directory before publishing:

  ```php
  // php -d memory_limit=1G <script>, after booting the app
  $manifest = App\Services\PackManifest::fromJson(file_get_contents($dir.'/manifest.json'));
  $result   = app(App\Services\PackValidation::class)->validate($manifest, $dir);
  // $result->passed(), $result->errors, $result->warnings
  ```

---

## What the artist has to supply for the next book

Per **book**:

- a folder name for `assets/books/<book>/` and `resources/books/<book>/`;
- a **title** as the player should read it;
- a `book_uid` — an authored slug like `coyote-2026`, decided once and **never changed or
  reused**, because every cloud save row keys off it (§6.1). It is not derived from the
  folder name and there is no rename path.

Per **page**, in page order:

1. **A display image** — the detailed art the player sees. Required. Delivered at print
   resolution with spaces in the filename is fine; normalising it is the pipeline's problem.
   The shipped copy goes to `assets/books/<book>/page_NN.png`, snake_case, ≤ 2048 px on the
   long edge.
2. **A masking image** — *optional*, and the artist's control over what a region is. Supply
   one whenever the visible line work is decoration rather than a colouring boundary (the
   coyote's fur ticks are decoration; the silhouette is the boundary). Since BL-12 the mask
   is **visible in game**, drawn over the paint and under the detail art, so draw it as
   something the player will see. Same aspect ratio as the display image — a mismatched
   aspect hard-fails, because that is two different drawings.
3. Originals of both go under `assets/books/<book>/source/` behind the `.gdignore`.

Then, per page: run `generate_region_map.gd` (mask as the positional source, display art via
`--display` when there is a mask), **look at the ID map** and the in-game debug overlay,
author the `PageDef` `.tres`, re-import (`--headless --import`), and only then `build_pack.gd`.
A giant-region failure means a line in the drawing has a gap — the artist must close it; no
flag and no server check can fix it.
