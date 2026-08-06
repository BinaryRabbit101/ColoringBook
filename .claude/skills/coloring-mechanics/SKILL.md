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
- `get_paint_image()` is a full GPU readback and **blocks** — dev harnesses and the app-quit save only. In the running game use `request_paint_image(callback)` (M6, async). Coverage must sparse-sample at stroke end either way.
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
- ~~**Known hazard for M6**: the synchronous readback stalls ~0.5s under FIFO vsync~~ — **fixed in M6**, see below. The readback is now async; `CoverageTracker` itself was not touched.
- Screens (`scenes/screens/`): `BookSelect` emits `book_chosen(book)`; `ColoringPage.load_book(book, start_index)` hosts PageView + mode palette + toolbar, emits `back_requested` / `book_completed(book)`. Screens never swap themselves — M5's `main.tscn` orchestrates. Set `GameState.mode` **before** instantiating ColoringPage (palette scene + threshold read at build time).
- `PageFlip` (`scenes/components/`): `prepare(from_texture)` freeze → swap page behind → `play_to(null)` reveals live content pixel-exact; 0.8s, `flip_finished`, swallows input only while playing.
- `GameState` book cursor: `start_book()`, `advance_page() -> bool`, `get_current_page()`, `current_page_label()`, `finish_book()`; signals `book_started`/`current_page_changed`/`book_finished`. Persist by `resource_path` + page index (M5).
- Full-flow smoke: `<godot_exe> --path godot res://scenes/dev/flow_smoke.tscn` (windowed) — also re-runs paint & palette smokes as child processes. Keep all three green.
- Gotcha: GDScript lambdas capture locals **by value** — use an array/dict cell for mutable counters in test callbacks.

### Implemented (M5) — app shell & persistence

- `main.tscn` / `scripts/main.gd` (`class_name Main`) is `run/main_scene` and the **only** node that knows the flow: Title → ModeSelect → BookSelect → ColoringPage → BookComplete. It frees/instantiates screens behind a 0.25 s fade, and owns the **overlays** (settings gear, settings panel, mid-book mode picker) — that is how `book_select.tscn` stayed frozen while gaining a settings entry point. `GameState.mode` is still set **before** ColoringPage is instantiated.
- `GameState` owns all of `user://` (nothing else opens a file there): `user://save_v1.json` (`{version, mode, books{<resource_path>: {slug, current_page_index, pages[]}}}`, statuses `untouched`/`in_progress`/`complete`) and `user://paint/<book_slug>/page_NN.png`. `book_slug` = book directory name sanitised + `_` + 8 hex of a hand-rolled FNV-1a of the full resource_path (hand-rolled so it cannot change with the engine). API: `save_now`/`load_save`/`get_book_progress`/`mark_page_status`/`erase_book_progress`/`erase_all_progress`/`get_paint_path`/`save_page_paint`/`load_page_paint`, signal `save_written`. `set_save_root()` is the **test isolation hook** — all four dev smokes point it at a scratch dir, because a restored paint layer would otherwise break their "starts blank" assertions.
- Save points for the paint layer (one `get_paint_image()` readback each, never more): page complete (before the flip advances), leaving the book, app quit (`NOTIFICATION_WM_CLOSE_REQUEST` / `APPLICATION_PAUSED`, handled in `main.gd` so the open page is flushed before the JSON).
- **Paint restore**: `PageView` is frozen and has no `set_paint_image()`, so `ColoringPage.PaintRestoreQuad` composites the saved PNG into the paint SubViewport for exactly ONE frame using `BLEND_MODE_PREMULT_ALPHA` over the freshly cleared (all-zero) target — that is bit-exact; plain MIX would darken soft dab edges on every save/restore cycle. The tracker is then re-seeded with `CoverageTracker.update_all(image)` using the same CPU image (no second readback). A page whose restored paint already completes it does **not** celebrate or flip (`is_page_pre_completed()`).
- Mode is now changeable mid-book: `ColoringPage` listens to `GameState.mode_changed`, rebuilds the palette component and re-injects the new `completion_threshold`, then re-settles with `update_all` so a *lower* threshold finishes regions immediately. Completion stays sticky in the other direction.
- Shell smoke: `<godot_exe> --path godot res://scenes/dev/shell_smoke.tscn` (windowed; `-- --stay`, `-- --shot-dir <dir>`).

### Implemented (M6) — the mobile pass

- **Renderer is now Mobile** (Vulkan), not Forward+. Chosen because Compatibility/OpenGL exposes **no `RenderingDevice`**, which would kill the async readback below; between the two Vulkan renderers, Mobile is the cheaper pipeline for a 2D game. DESIGN.md §3.5 has the evidence. Anything that touches `RenderingDevice` must still degrade gracefully when it is absent.
- **The paint readback is asynchronous.** `AsyncReadback` (`scripts/components/async_readback.gd`, static helpers over an injected `Viewport`) wraps `RenderingServer.texture_get_rd_texture()` → `RenderingDevice.texture_get_data_async()`. `PageView.request_paint_image(callback)` is the non-blocking twin of `get_paint_image()`; it returns **false without calling back** when the async path is unavailable, which is the caller's cue to fall back to the blocking call. Measured on the M6 dev box under default FIFO v-sync: **529.8 ms blocked synchronously → 0.10 ms** to queue the async one, image delivered on the **main thread** ~2 frames later.
  - `get_paint_image()` is still there and is still correct — dev harnesses and the app-quit save use it deliberately.
  - Two rules come with async: a readback can be a couple of frames stale (fine, coverage is monotonic and the completion flip already tolerated it), and **the engine must never be torn down while a readback is queued** — that is a reproducible hard crash (signal 11 during shutdown, any renderer). `AsyncReadback.drain(tree)` before any `SceneTree.quit()`; `main.gd` does it on close, every dev harness does it in `_finish()`.
- **`main.gd` owns the quit**: `SceneTree.auto_accept_quit` is off, and `NOTIFICATION_WM_CLOSE_REQUEST` runs save → drain → quit. `Main.quit_on_close_request = false` is the harness hook (it hands `auto_accept_quit` back so a `--stay` window still closes).
- **`ColoringPage` coverage** is a *loop* now (`_run_coverage_cycles`): a stroke ending during the two-frame flight lands in `_pending_regions` after the batch was taken, so the cycle repeats until that set is empty. Coalescing and skip-when-done are unchanged — five strokes in one burst still cost one readback.
- **Save points** unchanged in *when*, changed in *how*: page complete / leaving the book / navigating use `persist_current_page_settled()` (async); app quit uses `persist_current_page()` (blocking — there is no next frame to deliver to, and losing a page is worse than a stall on a frame nobody sees). Leaving the book **awaits** the save before emitting `back_requested`, or the parent would free the screen out from under the callback.
- **Page navigation**: `ColoringPage.can_go_to_page()` / `go_to_page()` / `furthest_reached_index()`, driven by prev/next buttons in the toolbar. Rule: any page already reached (max of the live cursor, the saved cursor, and the last page with a non-`untouched` status) is reachable, plus exactly one page forward when the current page is complete. A jump **saves first, then swaps instantly** — no flip. `is_transitioning()` now covers navigation too.
- **Portrait**: `ModeSelect` stacks its cards below aspect 1.0 (the holder is a plain `BoxContainer` — Godot refuses `set_vertical()` on `HBoxContainer`); `TitleScreen` sizes its paper and lettering to the screen instead of demanding 820 px; `ColoringPage` drops the toolbar's page title below 620 px; `SafeArea` (`scripts/components/safe_area.gd`) wraps `ScreenHost` + `Overlays` in `main.tscn` for notch margins (zero on a windowed desktop by design — `get_display_safe_area()` reports the *work area* there, not a cutout). Gotcha: `canvas_items`/`expand` stretch means the logical canvas never gets narrower than 1152 — portrait layouts must key off **aspect**, and width-driven ones have to be tested by resizing the screen `Control`, not the window.
- **First real art book**: `resources/books/coyote/` + `assets/books/coyote/` (page 1 outline, 2 regions; page 2 detail, 15 regions). The artist's full-resolution originals live in `assets/books/coyote/source/` behind a `.gdignore`.
- **Mobile smoke**: `<godot_exe> --path godot res://scenes/dev/mobile_smoke.tscn` (windowed; `-- --stay`, `-- --shot-dir <dir>`). It deliberately does **not** set the v-sync mode for its headline check — the async stall budget is only meaningful under default FIFO.

**Five smokes must stay green: paint 25, palette 59, flow 99, shell 91, mobile 104.**
