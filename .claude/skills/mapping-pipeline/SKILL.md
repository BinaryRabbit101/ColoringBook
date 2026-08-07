---
name: mapping-pipeline
description: The dev tool that parses a line-art page image and exports its vector region mapping (region ID map PNG + polygons JSON) for ColoringBook. Use when creating/editing tools/generate_region_map.gd, adding a new page or book, regenerating mappings, or debugging "player can paint where they shouldn't" / wrong-region issues. Triggers — "vector mapping", "region map", "id map", "add a page", "parse the image", "export regions".
---

# Mapping pipeline — page image → region data

Full spec: [docs/DESIGN.md](../../../docs/DESIGN.md) §3.1 & §4. The tool lives at `godot/tools/generate_region_map.gd` (dev-only; never referenced by game scenes).

## Running it

```
"c:\Users\binar\OneDrive\Desktop\Godot\Godot_v4.5.1-stable_win64.exe\Godot_v4.5.1-stable_win64.exe" \
  --headless --path "c:\Users\binar\Documents\ColoringBook\godot" \
  --script tools/generate_region_map.gd -- assets/books/<book>/page_01.png
```

Outputs next to the source image: `page_01_idmap.png` + `page_01_regions.json` (plus
`page_01_mask.png` on a `--display` run — see below).

### Display image vs masking image (BL-9, amended by BL-12)

Every page has a **display image** (the art the player sees) and an **optional masking image** (line
art that decides where paint may go, and that BL-12 also draws as a layer under the display art).
The positional argument is always the **mapping source**; when that is a mask, name the page's
display art with `--display`:

```
  --script tools/generate_region_map.gd -- assets/books/coyote/source/coyote_outline_source.png \
      --display assets/books/coyote/page_01.png
```

The artifacts are then written next to the **display** image (`page_01_idmap.png`,
`page_01_regions.json`, `page_01_mask.png`) because that is the page they belong to, and the mask is
resampled to the display image's dimensions when they differ — the artist's mask is print-resolution
while the shipped page fits the 2048 px budget, and an ID map that isn't pixel-for-pixel the display
image is unusable. A mismatched **aspect** hard-fails instead (that is not the same drawing twice).

**`page_01_mask.png` is that resample, and it SHIPS** (BL-12 reversed BL-9's "never shipped, never
loaded"): the runtime draws it between the paint layer and the display art, so its outlines stay
visible over the colour. `PageDef.mask_image_path` therefore points at this artifact — never into the
`.gdignore`d `source/` folder, which `PageDef.validate()` now rejects — while the artist's print-size
original stays out of the build and is recorded in the JSON's `mask_image` field for provenance.

Optional per-run overrides (M6) after the source path — `--display`, `--line-alpha-min`, `--line-luminance-max`,
`--dilate`, `--min-area`, `--rdp`, `--giant-fraction`. The defaults are still the constants at the
top of the script; the values actually used are printed in the run summary, so a page's mapping is
always reproducible from its log. Prefer a flag over editing a constant: constants are shared by
every page in the project.

## Algorithm (keep this order)

1. **Binarize** — line pixel = alpha/darkness above a configurable threshold. Source art: dark line work, transparent or white elsewhere.
2. **Flood-fill segmentation** of non-line pixels → connected regions. Drop specks under a minimum area (noise from anti-aliasing).
3. **ID assignment** — region id encodes into the ID-map pixel as RGB: `id = R<<16 | G<<8 | B`; `#000000` reserved for lines/unpaintable. Write `_idmap.png` (lossless).
4. **Vector trace** — marching squares around each region → outline + holes; simplify with Ramer–Douglas–Peucker (configurable tolerance); compute centroid + pixel area. Write `_regions.json`.
5. **Report & fail loudly** — print region count, dropped specks, min/max area. Hard-fail on zero regions or one giant region covering most of the image (symptom: a **gap in the line art** merged everything — the artist must close the gap or the threshold needs tuning).

## JSON schema (version 1)

```json
{
  "version": 1,
  "source_image": "page_01.png",
  "mask_image": "coyote_outline_source.png",
  "image_size": [w, h],
  "regions": [
    { "id": 3, "id_color": "#000003",
      "outline": [[x,y], ...], "holes": [[[x,y], ...]],
      "centroid": [x,y], "area_px": 15234 }
  ]
}
```

`source_image` is the display page the artifacts belong to; `mask_image` appears only when a separate
masking image was traced (BL-9), so a page's mapping stays reproducible from the JSON alone.
Coordinates are image pixel space; `outline`/`holes` vertices are pixel-corner (marching-squares) coordinates while `centroid` is a pixel index, snapped to a pixel the region owns (`CENTROID_SNAP_TO_REGION`) so it's usable as a tap-hint even when the strict mean lands in a hole. `area_px` counts ID-map pixels (post-dilation). Consumers: hit-testing uses the **ID map**, not these polygons; polygons serve debug overlay, centroids/areas, coverage sample grids (see `coloring-mechanics`).

## Invariants & gotchas

- ID map and **display** image must be **identical dimensions**; anti-aliased line edges belong to the **line** (unpaintable), never to a region — a 1-px halo of `#000000` around lines is correct and prevents edge bleed.
- The `_idmap.png` **import settings** must stay lossless: `compress/mode=0`, `mipmaps/generate=false`, `detect_3d/compress_to=0` (the default `1` silently VRAM-compresses on 3D detection), `process/fix_alpha_border=false`. Filtering is a per-usage sampler setting in Godot 4, not an import flag — set `TEXTURE_FILTER_NEAREST` where the ID map is sampled. If regions "bleed" at boundaries in-game, check the `.import` file first.
- Generated files are build artifacts of the source PNG: **never hand-edit**; re-run the tool after any art change, and commit source + every output + the `.import` files together.
- Adding a new page = drop the display PNG under `assets/books/<book>/` (plus its masking image under `source/`, if it has one), run the tool, create/update the `PageDef` `.tres` — `display_image_path` + the artifact paths, and `mask_image_path` pointing at the generated `page_NN_mask.png` (**not** at the `source/` original) — then re-import (`--headless --import`, or the new artifact is invisible to a CLI run) and verify with the in-game debug overlay (region tinting) before calling it done.
- Keep thresholds/tolerances as script constants at the top of the file with comments — pages vary in line weight and will need tuning. Tune a single page with a CLI flag, not by editing the constant.
- **Source art belongs to the artist**: keep the untouched original next to the page under `assets/books/<book>/source/` with an empty `.gdignore` in that folder (Godot skips it, the Android preset excludes it), and put the *shipped* page — snake_case, within the 2048 px budget — at `assets/books/<book>/page_NN.png`. Real art arrives with spaces in the filename and at print resolution; both are the pipeline's problem, not the artist's.
- **What "it mapped" means for real art** (M6, the coyote book): a hand-drawn page maps to the regions the *artist actually closed*, which is usually far fewer than the shapes a human sees. Contour lines that stop in mid-air (fur ticks, a leg outline that fades into a ruff) enclose nothing, so the whole body comes back as one region. That is correct output, not a failure — the failure mode to watch for is the giant-region check firing, i.e. paint leaking *between* shapes through a gap. Check the ID map visually before believing either verdict.
- **A mask is how the artist controls that** (BL-9): the coyote page's detail art is full of fur ticks and inner contours, but its regions come from a plain silhouette mask — coyote + paper, 2 regions. The player colours the whole animal in one sweep with every detail line still drawn on top. Reach for a mask whenever the visible art's line work is decoration rather than a colouring boundary. Since BL-12 the mask is also **visible**, drawn over the paint and under the detail art, so it doubles as the region guide the detail lines do not give — draw it like something the player will see, not like scaffolding.
