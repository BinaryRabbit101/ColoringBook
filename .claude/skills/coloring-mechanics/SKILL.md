---
name: coloring-mechanics
description: How ColoringBook's core coloring mechanic works and must be implemented — region lock on press, GPU-clipped painting via the ID map, stroke lifecycle, coverage/completion, palettes per mode. Use for any work on the coloring page, brush, painting shader, palette, input handling, or completion logic. Triggers — "paint", "brush", "stroke", "region", "stay inside the lines", "palette", "crayon", "page complete", "flip".
---

# Coloring mechanics — the core invariants

Full design: [docs/DESIGN.md](../../../docs/DESIGN.md) §1–3. These are the rules implementation must not violate.

## The non-negotiable mechanic

1. On **press**, sample the region **ID map** at the press point → that region becomes the *locked region* for the whole stroke. Pressing on a line / non-paintable pixel (`#000000`) starts **no** stroke.
2. While **held/dragging**, paint lands **only inside the locked region** — even when the pointer crosses lines into other regions. Never re-lock mid-stroke.
3. On **release**, the stroke ends; update per-region coverage; check page completion. Next press may lock any region.

## How painting is constrained (GPU, not CPU)

- Paint strokes render into a **SubViewport** sized to the page image (stamped brush quads, interpolated along the drag so fast drags leave no gaps).
- The brush shader samples the **ID-map texture** and `discard`s fragments where the ID-map color ≠ the locked region's `id_color` (passed as a uniform). Stroke geometry may freely overlap lines; the shader does the clipping.
- Layer order (back → front): paper background → SubViewport paint texture → line-art texture (lines drawn on top).
- **Never** implement per-pixel CPU painting with region checks — it will not hold up on mobile.
- ID map must stay lossless: `.import` keeps `compress/mode=0`, `mipmaps/generate=false`, and `detect_3d/compress_to=0` (default `1` silently VRAM-compresses if the texture is ever seen in 3D — corrupts region IDs). Filtering is **not** an import flag in Godot 4: set `TEXTURE_FILTER_NEAREST` on the node/material that samples the ID map. Guard the `.import` file in diffs.

## Hit-testing & region data

- Press → region id: **pixel lookup in the ID map** (exact, handles enclosed holes for free).
- The `_regions.json` polygons are for: debug overlay tinting, centroids (hint markers), areas, and coverage sample grids — not the paint clip itself.
- Region id encodes into RGB as `id = R<<16 | G<<8 | B`; `#000000` reserved for lines/unpaintable.

## Coverage & completion

- Per region, precompute a sparse grid of sample points (from polygons + area). On **stroke end** (not per frame), sample the paint SubViewport at those points to update coverage. No full-image readbacks in the paint loop.
- A region is "done" at coverage ≥ threshold; a page is complete when all regions are done. Thresholds come from the mode: **Child = generous, Adult = strict** (values in `PaletteDef`/mode config, not hardcoded).
- Page complete → page-flip transition → next page (see DESIGN.md §2).

## Input rules (mobile + PC, one code path)

- Use `InputEventScreenTouch` / `InputEventScreenDrag` with *Emulate Touch From Mouse* on — never separate mouse and touch branches.
- Two-finger gesture (pinch/pan) **cancels** an accidental single-finger stroke start.
- Pan/zoom lives on the page view; painting coordinates must be transformed page-local before ID-map lookup.

## Palettes by mode

- One coloring flow; mode only swaps the palette component and thresholds. Never fork gameplay per mode.
- **Child**: `palette_child.tscn` — a row of 8–12 chunky crayons, large touch targets, big forgiving brush.
- **Adult**: `palette_adult.tscn` — swatch grid and/or fine picker, more shades, brush size control.
- Both emit the same signal (`color_picked(color)`); colors and brush sizes come from `PaletteDef` `.tres` resources, not code.
