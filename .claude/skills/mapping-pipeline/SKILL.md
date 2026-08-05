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

Outputs next to the source image: `page_01_idmap.png` + `page_01_regions.json`.

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
  "image_size": [w, h],
  "regions": [
    { "id": 3, "id_color": "#000003",
      "outline": [[x,y], ...], "holes": [[[x,y], ...]],
      "centroid": [x,y], "area_px": 15234 }
  ]
}
```

Coordinates are image pixel space. Consumers: hit-testing uses the **ID map**, not these polygons; polygons serve debug overlay, centroids/areas, coverage sample grids (see `coloring-mechanics`).

## Invariants & gotchas

- ID map and base image must be **identical dimensions**; anti-aliased line edges belong to the **line** (unpaintable), never to a region — a 1-px halo of `#000000` around lines is correct and prevents edge bleed.
- The `_idmap.png` **import settings** must stay lossless + `filter: nearest`, no mipmaps. If regions "bleed" at boundaries in-game, check the `.import` file first.
- Generated files are build artifacts of the source PNG: **never hand-edit**; re-run the tool after any art change, and commit source + both outputs + `.import` together.
- Adding a new page = drop the line-art PNG under `assets/books/<book>/`, run the tool, create/update the `PageDef` `.tres`, then verify with the in-game debug overlay (region tinting) before calling it done.
- Keep thresholds/tolerances as script constants at the top of the file with comments — pages vary in line weight and will need tuning.
