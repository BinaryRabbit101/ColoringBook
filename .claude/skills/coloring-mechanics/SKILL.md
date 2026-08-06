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

## PageView component (implemented — M2)

`scenes/components/page_view.tscn` / `scripts/components/page_view.gd` (`class_name PageView`) is the built, verified painting component. Read its doc comments for the full API; load-bearing facts:

- Inject pages via `load_page(base, idmap, regions)` or the three exported path properties — never hardcode page paths inside it.
- Signals: `page_loaded(page_size)`, `region_locked(region_id)`, `stroke_ended(region_id)` (the coverage hook — fires exactly once per stroke, **including after a cancel**, since committed paint remains), `stroke_cancelled(region_id)` (fires just before `stroke_ended` on aborts).
- `brush_size` is **diameter** in page pixels (default 56); parent sets `brush_color`/`brush_size`/`brush_hardness`.
- `get_region_id_at(page_pos)` → 0 = line art, -1 = out of bounds. `get_region_data(id)` returns the JSON region dict for coverage-grid precomputation.
- `get_paint_image()` is a full GPU readback — **debug only**, never in the paint loop. Coverage must sparse-sample at stroke end.
- Region clipping lives in `scenes/components/brush.gdshader` (`id_epsilon` = half an 8-bit step; ID map sampled with `filter_nearest` hint). The SubViewport is never cleared (`CLEAR_MODE_ONCE`→NEVER); `PaintCanvas` draws only the pending stamp batch each frame.
- Smoke test: `<godot_exe> --path godot res://scenes/dev/paint_smoke.tscn` (windowed — headless can't render the SubViewport; append `-- --stay` for manual play, F1 toggles the region overlay). Keep it green after any change to the painting stack.

## Palettes by mode

- One coloring flow; mode only swaps the palette component and thresholds. Never fork gameplay per mode.
- **Child**: `palette_child.tscn` — a row of 8–12 chunky crayons, large touch targets, big forgiving brush.
- **Adult**: `palette_adult.tscn` — swatch grid and/or fine picker, more shades, brush size control.
- Both emit the same signal (`color_picked(color)`); colors and brush sizes come from `PaletteDef` `.tres` resources, not code.

### Implemented (M3) — build against these, don't reinvent

- `PaletteDef` (`scripts/resources/palette_def.gd`): colors, `shades_per_family` (adult grid grouping — render via `family_count()`/`get_family(i)`, never assume a flat list), `brush_sizes` (**diameters**, feed `PageView.brush_size` directly), `default_brush_hardness`, and `completion_threshold` (0.70 child / 0.92 adult) — M4+ reads thresholds from here, never hardcodes.
- `GameState` autoload (`autoload/game_state.gd`): `mode`, `set_mode()`, `mode_changed` signal, `get_active_palette()`, `get_palette_scene_path()`. Extend it for book/page state and persistence (M5) — no second autoload.
- Palette components (`palette_child.tscn` crayon row / `palette_adult.tscn` swatch grid): identical contract — `set_palette(def)` (auto-emits `brush_size_picked` then `color_picked` once each, so the brush is always primed), `color_picked(color)`, `brush_size_picked(size)`. Wiring a coloring screen = instantiate `GameState.get_palette_scene_path()`, connect those two signals to `PageView.brush_color`/`brush_size`, set `brush_hardness` from the def, call `set_palette`.
- Smoke test: `<godot_exe> --path godot res://scenes/dev/palette_smoke.tscn` (windowed; `-- --stay` to inspect, `-- --shot <path>` saves a screenshot). Keep green alongside paint_smoke.

### Implemented (M4) — books, coverage, flip

- `PageDef`/`BookDef` resources (`scripts/resources/`); books are **discovered**, never preloaded: `BookDef.discover()` scans `res://resources/books/*/book.tres` — adding a book = adding a folder.
- `CoverageTracker` (RefCounted, `scripts/components/coverage_tracker.gd`): ~240 sample points/region (polygon-inside, hole-and-line-filtered against the ID map), threshold **injected** from the active `PaletteDef`, one `get_paint_image()` readback per stroke end (coalesced while in flight; skipped when all pending regions done), coverage monotonic. `update_all(image)` restores coverage from a saved paint layer (persistence hook).
- **Known hazard for M6**: the synchronous readback stalls ~0.5s under FIFO vsync (presentation pacing, not bandwidth — ~2ms with mailbox/disabled vsync). Proper fix: `RenderingDevice.texture_get_data_async()`.
- Screens (`scenes/screens/`): `BookSelect` emits `book_chosen(book)`; `ColoringPage.load_book(book, start_index)` hosts PageView + mode palette + toolbar, emits `back_requested` / `book_completed(book)`. Screens never swap themselves — M5's `main.tscn` orchestrates. Set `GameState.mode` **before** instantiating ColoringPage (palette scene + threshold read at build time).
- `PageFlip` (`scenes/components/`): `prepare(from_texture)` freeze → swap page behind → `play_to(null)` reveals live content pixel-exact; 0.8s, `flip_finished`, swallows input only while playing.
- `GameState` book cursor: `start_book()`, `advance_page() -> bool`, `get_current_page()`, `current_page_label()`, `finish_book()`; signals `book_started`/`current_page_changed`/`book_finished`. Persist by `resource_path` + page index (M5).
- Full-flow smoke: `<godot_exe> --path godot res://scenes/dev/flow_smoke.tscn` (windowed) — also re-runs paint & palette smokes as child processes. Keep all three green.
- Gotcha: GDScript lambdas capture locals **by value** — use an array/dict cell for mutable counters in test callbacks.
