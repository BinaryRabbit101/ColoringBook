# ColoringBook — Design & Implementation Handoff

Godot **4.5.1** project in [godot/](../godot/). Mobile (Android/iOS touch) **and** PC (mouse) from day one.
This document is the source of truth for implementing agents. Read it fully before writing code.
Project conventions live in `.claude/skills/` — follow them.

## 1. Game overview

A digital coloring book. The player:

1. Picks a **mode**: **Child** or **Adult** — this changes palette difficulty and UI presentation.
2. Picks a **coloring book** (a collection of pages).
3. Colors the current page. When the page is complete, the book **flips to the next page**.

### The core coloring mechanic (the heart of the game)

- Each page has a **base image**: line art (dark outlines + details) drawn over a paintable surface.
- A **vector mapping** (precomputed, per page) divides the page into closed **regions** (the areas between the lines).
- The player picks a color, then **presses down inside a region**. The region under the initial press becomes the *locked region* for that stroke.
- **For as long as the press/drag is held**, paint is applied **only inside the locked region** — the brush can wander over the lines, but pixels land exclusively within that region's boundary. This is the "can't color outside the lines" guarantee.
- Releasing ends the stroke. The next press locks a (possibly different) region.

### Difficulty modes

| | Child | Adult |
|---|---|---|
| Palette | Short row of **crayons** (8–12 bold colors), large touch targets | Larger swatch grid and/or fine color picker, many colors/shades |
| Brush | Large, forgiving | Finer sizes, optional size control |
| Completion | Generous (region counts done at lower coverage) | Stricter coverage threshold |
| UI | Big, playful, minimal text | Denser, more options |

Mode is chosen at startup (and changeable from settings); it parameterizes the palette scene and thresholds — **do not fork the game flow per mode**. One flow, mode-driven configuration.

## 2. Player flow

```
TitleScreen ──► ModeSelect (Child / Adult)
                    │
                    ▼
              BookSelect (grid of book covers)
                    │
                    ▼
              ColoringPage ◄────────────┐
                    │  page complete    │
                    ▼                   │
              PageFlip animation ───────┘   (next page; after last page → BookComplete → BookSelect)
```

Progress (which pages are colored, per book, per mode) persists to `user://` via a save system.

## 3. Technical architecture

### 3.1 The vector mapping (per-page data)

Produced offline by the **mapping pipeline** (§4), shipped with the page art. Two artifacts per page:

1. **`<page>_regions.json`** — vector data:
   ```json
   {
     "version": 1,
     "source_image": "page_01.png",
     "image_size": [2048, 2048],
     "regions": [
       {
         "id": 3,
         "id_color": "#000003",
         "outline": [[x, y], ...],
         "holes": [[[x, y], ...]],
         "centroid": [x, y],
         "area_px": 15234
       }
     ]
   }
   ```
   `outline`/`holes` are polygons in image pixel space (marching-squares traced, simplified); vertices are pixel-corner coordinates, while `centroid` is a pixel index. `centroid` is snapped to a pixel the region actually owns (an area-weighted mean can land inside a hole — useless as a tap-hint marker). `area_px` counts ID-map pixels (post line-dilation), making the ID map and JSON agree exactly.
2. **`<page>_idmap.png`** — a lossless **region ID map**: same dimensions as the base image, every pixel of region *N* has the flat color encoding *N* (`#000000` reserved: lines / not paintable). This is the runtime workhorse.

**Runtime roles:**
- **Hit-test (press → region id):** sample the ID map pixel at the press point (fast, exact, handles holes for free). The JSON polygons are the authored/portable representation and serve editor tooling, debug overlays, and centroid/area queries (e.g. completion, "tap hint" markers).
- **Paint constraint:** shader-based mask — see §3.2.

### 3.2 Constrained painting (performance-critical)

Do **not** CPU-paint pixels with per-pixel region checks on mobile. Use the GPU:

- The paint surface is a **`SubViewport`** the size of the page image; strokes are drawn into it (stamped brush quads along the drag path, interpolated so fast drags leave no gaps).
- The brush material's **shader samples the ID-map texture** and `discard`s any fragment whose ID-map color ≠ the locked region's `id_color`. The stroke geometry can freely cross lines; the shader clips it to the region.
- Scene layering (back → front): paper background → SubViewport paint texture → line-art texture (lines on top, transparent elsewhere).
- The ID map **must** stay lossless end-to-end or region IDs bleed at edges. In Godot 4 that means: `.import` keeps `compress/mode=0`, `mipmaps/generate=false`, **and `detect_3d/compress_to=0`** (the default `1` silently re-imports as VRAM-compressed if the texture is ever seen in a 3D context). Texture *filtering* is not an import flag — set `TEXTURE_FILTER_NEAREST` on the node/material that samples the ID map.

Per-region **coverage tracking** for completion: count painted pixels per region. Cheap approach: on stroke end, sample the SubViewport texture at a sparse grid of points per region (precomputed from the polygons) rather than reading back full images every frame. Threshold per mode (§1).

The readback itself is **asynchronous** (M6): `RenderingDevice.texture_get_data_async()` via `scripts/components/async_readback.gd`, because the synchronous `Viewport.get_texture().get_image()` blocks the main thread for the length of the presentation queue — 350–530 ms under the default FIFO v-sync, on every stroke end. Two rules come with it: a readback may be **stale by a couple of frames** (harmless, coverage is monotonic), and the engine must **never be torn down while one is queued** (`AsyncReadback.drain()` before any `SceneTree.quit()`; it is a hard crash otherwise).

### 3.3 Input

- Handle **both** mouse and touch through `InputEventScreenTouch`/`InputEventScreenDrag` with *Emulate Touch From Mouse* enabled in project settings — one code path.
- Stroke lifecycle: `press` → lock region (ID-map lookup) → `drag` events append stamped brush segments (clipped by shader) → `release` → finalize stroke, update coverage, check page completion.
- Pressing on a line/outside any region (`#000000`) starts **no** stroke.
- Pan/zoom (pinch on mobile, wheel + middle-drag on PC) on the page view; a two-finger gesture must **cancel** an accidental one-finger stroke start.

### 3.4 Scene & autoload structure

Follow official best practices: scenes self-contained, **signals up / calls down**, dependency injection from parents; autoloads only for genuinely global state.

```
godot/
  scenes/
    main.tscn                # entry point: swaps screens
    screens/title_screen.tscn
    screens/mode_select.tscn
    screens/book_select.tscn
    screens/coloring_page.tscn   # page view + palette + toolbar
    components/palette_child.tscn    # crayon row
    components/palette_adult.tscn    # swatch grid / picker
    components/page_view.tscn        # SubViewport painting stack, pan/zoom
    components/page_flip.tscn        # flip transition
  scripts/                   # mirrors scenes/; snake_case.gd
  resources/
    books/<book_name>/book.tres      # BookDef: title, cover, ordered page list
    books/<book_name>/pages/         # PageDef .tres per page
    palettes/child_palette.tres, adult_palette.tres
  assets/
    books/<book_name>/page_01.png / page_01_idmap.png / page_01_regions.json
  autoload/
    game_state.gd            # current mode, current book/page, save/load progress
  tools/
    generate_region_map.gd   # the mapping pipeline (§4) — dev-only, headless
```

Custom `Resource` types (`class_name`): `BookDef`, `PageDef` (paths to base/idmap/regions + display name), `PaletteDef` (mode, colors, brush sizes). Data in `.tres`, logic in nodes.

One autoload: `GameState`. Screens communicate upward via signals; `main.tscn` swaps screens and injects dependencies (e.g. hands `PageDef` + `PaletteDef` to the coloring screen).

### 3.5 Mobile considerations

- **Renderer: Mobile** (`rendering/renderer/rendering_method="mobile"`, Vulkan) — decided in M6, evaluated empirically on the dev box (RTX 5060, Godot 4.5.1) rather than from documentation. This is a pure 2D game, so the deciding factor was not raster performance (all three renderers draw a handful of quads and one `canvas_item` shader without breaking a sweat) but **API availability**:
  - Forward+ and Mobile are both Vulkan and both expose a `RenderingDevice`, so `RenderingServer.texture_get_rd_texture()` → `RenderingDevice.texture_get_data_async()` works — that is the asynchronous paint-layer readback the coloring loop depends on (§3.2).
  - **Compatibility (`gl_compatibility`) is OpenGL and `RenderingServer.get_rendering_device()` returns null**, so there is no async readback at all. Every coverage update would fall back to the blocking one, which measures **350–530 ms** under the default FIFO v-sync. That disqualifies it as the shipping renderer.
  - Between Forward+ and Mobile, Mobile wins on cost: it is the tile-GPU-oriented pipeline (single-pass forward, no clustered-lighting/decal/SDFGI machinery to set up per frame), which means less bandwidth and less battery for output that is pixel-identical here. All five smoke tests pass under it on Windows.
  - Compatibility remains the fallback for a device with no Vulkan 1.0 driver. The code degrades rather than breaks: `AsyncReadback.request()` returns false and the caller uses the synchronous readback.
- Textures: page art up to 2048×2048; keep ID maps lossless (VRAM-uncompressed) — they are correctness-critical. `rendering/textures/vram_compression/import_etc2_astc=true` gives ETC2/ASTC for everything else.
- Touch targets ≥ 48 px logical (child-mode controls use 64+, the settings gear 72); UI uses anchors/containers for portrait/landscape, and `scripts/components/safe_area.gd` wraps the shell in notch-safe margins.
- Window stretch mode `canvas_items`, aspect `expand`. **Consequence worth knowing**: with the 1152×648 base viewport, a portrait window never narrows the logical canvas below 1152 — it grows the *height* instead (a 720×1280 window becomes a 1152×2048 canvas). Portrait layouts therefore key off **aspect ratio**, not width.
- Orientation: `display/window/handheld/orientation=6` (SENSOR) — portrait and landscape both allowed.
- Android export: `godot/export_presets.cfg`, preset `Android`. See [ANDROID.md](ANDROID.md).

## 4. Mapping pipeline (dev tool, not shipped gameplay code)

`godot/tools/generate_region_map.gd` — run headless:

```
<godot_exe> --headless --path godot --script tools/generate_region_map.gd -- assets/books/<book>/page_01.png
```

Steps:
1. Load the line-art PNG; binarize: line pixels = alpha/darkness above threshold (configurable).
2. **Flood-fill segmentation** of non-line pixels → connected regions; discard specks below a minimum area (noise).
3. Assign each region an id and an `id_color` (encode id in RGB, e.g. `id = R<<16|G<<8|B`); write **`_idmap.png`**.
4. **Marching squares** around each region → outline (+ holes), simplify (Ramer–Douglas–Peucker, tolerance configurable); compute centroid & area; write **`_regions.json`** (§3.1 schema).
5. Print a summary (region count, dropped specks, min/max area) and fail loudly on: unclosed line gaps producing one giant region, or zero regions.

Also provide a **debug overlay** toggle in `page_view.tscn` that tints regions from the JSON polygons — the fastest way to verify a page's mapping in-game.

## 5. Implementation milestones (suggested agent work order)

1. **M1 — Mapping pipeline**: `generate_region_map.gd` + one hand-made test page (simple shapes). Verify JSON + ID map outputs. *Everything else depends on this.*
2. **M2 — Page view & constrained painting**: `page_view.tscn`, SubViewport stack, brush shader with ID-map clipping, stroke lifecycle, pan/zoom. Test with M1's page.
3. **M3 — Palettes & modes**: `PaletteDef`, child crayon row, adult swatches, brush sizes, `GameState.mode`.
4. **M4 — Books, pages, completion & flip**: `BookDef`/`PageDef`, coverage tracking, completion thresholds, page-flip transition, book select screen.
5. **M5 — Shell & persistence**: title, mode select, save/load progress, settings.
6. **M6 — Mobile pass**: renderer evaluation (§3.5), async paint readback, portrait/safe-area layout pass, page navigation, the first real art book (`coyote`), Android export preset. Device profiling still pending — no Android hardware or 4.5.1 export templates on the dev box; see [ANDROID.md](ANDROID.md).

Each milestone must end with the project running clean (no errors in debug output) via the godot-mcp `run_project` → `get_debug_output` loop.
