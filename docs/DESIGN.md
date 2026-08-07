# ColoringBook — Design & Implementation Handoff

Godot **4.5.1** project in [godot/](../godot/). Mobile (Android/iOS touch) **and** PC (mouse) from day one.
This document is the source of truth for implementing agents. Read it fully before writing code.
Project conventions live in `.claude/skills/` — follow them.

## 1. Game overview

A digital coloring book. The player:

1. Picks a **coloring book** (a collection of pages).
2. Colors **any page they like, for as long as they like**. Completion is a celebration, never a gate — see §2.1 (free play).

There is **no Child/Adult mode choice** — removed 2026-08-07 (BL-20; the split existed from M3 through BL-19, and older sections of the backlog describe it as it was).

### The core coloring mechanic (the heart of the game)

- Each page has a **base image**: line art (dark outlines + details) drawn over a paintable surface.
- A **vector mapping** (precomputed, per page) divides the page into closed **regions** (the areas between the lines).
- The player picks a color, then **presses down inside a region**. The region under the initial press becomes the *locked region* for that stroke.
- **For as long as the press/drag is held**, paint is applied **only inside the locked region** — the brush can wander over the lines, but pixels land exclusively within that region's boundary. This is the "can't color outside the lines" guarantee.
- Releasing ends the stroke. The next press locks a (possibly different) region.

### The palette — one crayon row (BL-20…BL-23)

One palette for everyone: the **crayon row** (formerly the "child" palette) — 8–12 bold
colors as crayons, large touch targets, a single forgiving brush, and the generous
completion threshold (**0.90**, BL-5's child value). The former Adult mode — swatch grid,
fine color picker, brush-size slider, stricter threshold — is **removed** along with the
mode-select screen and the settings mode switch (BL-20). One flow, no mode parameter.

The crayon row grows three features (designed 2026-08-07):

- **Intensity (BL-22).** Every crayon color has a light→dark range. A swap control on the
  row toggles it between **color crayons** and **intensity crayons**: after picking a
  color, swapping redraws the same row as shades of that color from a pale tint to a deep
  shade; picking one sets the paint color, and swapping back returns to the colors. The
  intensity ladder is **derived** from the base color (a fixed set of ~7 computed steps,
  never authored per color), so every crayon set gets it for free. The active pick is
  always *base color + intensity step*; `color_picked` carries the resolved color and
  nothing downstream of the palette changes.
- **Crayon boxes (BL-23, rebuilt by BL-35).** Mario-Paint-style fun: additional authored
  **crayon sets** beyond the default box, cycled with a **cycle bar at each end of the
  strip** (BL-34: back at one end, forward at the other, both outside the crayon
  scroller). Which box is out is drawn as a pip row on the bars plus a transient name
  banner on every cycle — no permanent label, because the strip is built for a child who
  cannot read yet. BL-23 shipped five recolours (Pastel, Neon, Earth, Candy, Spooky) and
  the playtest verdict was "more colour options, not more fun" — so **every box now
  carries the SAME crayon lineup and differs in its FINISH**, each box louder than the
  one before: classic wax → **Neon Glow** (strokes bloom) → **Textured Wax** (visible
  crayon grain) → **Glitter** (grain, drifting rainbow bands and specks of glitter). A
  set authors a finish and, normally, no colours at all — it inherits the palette's
  lineup.
  - **A finish is how the paint LOOKS, never how the game PLAYS.** That is the exact width
    of BL-35's amendment to BL-23's "colours and nothing else": brush diameter, hardness
    and the completion threshold remain forbidden on a crayon set and remain on the base
    palette, because a box that could move those would be a difficulty mode again (§3.4,
    BL-20). Adding a finish changes the pixels a stroke lays down and nothing else.
  - Finishes are **baked into the stamp** by the brush shader, so the flattened paint layer
    — and the saved PNG — carries them for free, and the region clip owns every one of them
    (a glow halo is discarded outside the locked region exactly like the core of the dab).
    Animated/live finishes need an effect channel or persistent per-stroke metadata and are
    deliberately a later phase (BL-38).
  - The finish reaches the paint path on its own palette signal (`brush_effect_picked`);
    `color_picked` still carries one resolved colour and nothing else, and the crayon
    buttons preview their box's finish so a box sells itself before the first stroke.
- **Layout (BL-21).** In portrait the crayon row sits along the bottom of the canvas
  (unchanged — it reads well). In **landscape the crayons dock on the side of the canvas**
  as a vertical column instead of eating the already-short screen height. Same palette
  scene, orientation-keyed layout (key off aspect ratio, not width — §3.5).
- **Every crayon is visible, always (BL-33).** The strip never scrolls: it sizes its
  crayons to the room it has (available length ÷ count, floored at the 64 px touch
  target) and wraps onto a second rank across the strip when the floor is reached. A
  crayon off the end of a scroller is a crayon that does not exist.
- **The cycle ring runs on into STICKERS (BL-36).** Past the last crayon box the same
  carousel reaches this device's **sticker sets**: the strip swaps its crayons for a row
  of sticker cards, the name banner shouts the set exactly as it shouts "Neon!", and
  cycling on past the last set wraps home to crayon box 0. One ring, one index, the same
  two cycle bars — their pips count *stages*, not boxes.
  - **A sticker is not paint, and that is the whole design.** It is placed on TOP of the
    line art (never region-clipped, never counted toward coverage, never in the paint
    layer or the saved PNG), at a slight random tilt, with a plop-and-settle animation
    and a size that is a fraction of the page rather than a pixel count.
  - **Sticker mode turns painting off through BL-10's one gate** (`painting_enabled`), so
    the press comes back as `paint_blocked` and the screen places instead of painting —
    no second input path. The **padlock outranks it**: a locked page takes neither paint
    nor stickers.
  - Placing one is an undoable **BL-17 entry on the same timeline as the strokes** (undo
    takes back the last *thing*, whichever kind it was), and the per-page placement list
    is an **additive key in the save** beside `status`/`locked` — a few numbers per
    sticker, so it round-trips exactly at any page resolution.
  - Sticker sets are **catalog content, not palette data** (BL-37): discovered from
    installed packs under `user://dlc`, with the repo's "Starter Stickers" fixture set
    excluded from every release export exactly like `resources/books/*` (BL-25).

## 2. Player flow

```
TitleScreen ──► BookSelect (grid of book covers)
                    │
                    ▼
              ColoringPage ◄──► free page navigation (any page, any order, any time)
                    │  Back (the only way out of a book)
                    ▼
              BookSelect
```

There is **no separate completion screen** — neither for a page nor for the
book (BL-11). Completion is celebrated on the coloring page itself (§2.2).

Progress (which pages are colored, per book) persists to `user://` via a save system.

### 2.1 Free play, completion & the coloring lock (BL-10)

Completing a page is **never a requirement** for anything. The rules:

- **Any page, any time.** Every page of an open book is always reachable through
  the prev/next navigation — no page is gated behind completing an earlier one.
  A brand-new book starts with all of its pages selectable. (The page-flip
  ceremony remains reserved for the forward step off a page the player just
  finished; every other jump is an instant swap, per BL-4.)
- **Color for as long as you want.** Coverage thresholds decide when the
  *celebration* fires, not when coloring stops. A page that has reached
  "complete" stays fully paintable — the player can keep adding strokes in the
  same sitting or reopen the page days later and continue. Completion status is
  sticky (it never downgrades except via *Start over*, BL-7), and re-painting a
  complete page must not re-fire the celebration.
- **The last page is not special (BL-11).** Completing the last page behaves
  exactly like completing any other page: the transient celebration (§2.2)
  plays and the player stays put. Its forward arrow is simply disabled — there
  is no next page — and leaving the book is what it always is: the Back
  button. There is no book-complete gesture, signal, or screen. Nobody is
  yanked away from a page they are still enjoying.
- **The coloring lock.** A padlock toggle in the coloring-page toolbar guards
  against accidents (a finished page the player wants to protect, or handing the
  device over just to *show* a page). While locked:
  - presses on the page start **no stroke** (pan/zoom and two-finger gestures
    still work — the lock stops paint, not looking);
  - **Start over** is disabled (the lock's whole job is preventing accidental
    damage);
  - Save, navigation and palette browsing are unaffected;
  - tapping the page gives lightweight feedback (e.g. the padlock wiggles) so a
    child understands why nothing is happening.
  The lock is **per page** and **persists** in the save file, so a protected
  page stays protected across sessions. Unlocking is the same single toggle —
  visible, obvious state, no confirmation dialog needed.

### 2.2 Completion celebration (BL-11)

Completing a page triggers a **transient, on-page** celebration — the only
completion presentation in the game:

- A congratulatory message, picked **at random** from an authored pool
  ("This looks fantastic!", "Beautiful work!", "So colorful!", …), appears
  **above the page** together with a **confetti burst** (palette-colored
  scraps, no art assets — the `CPUParticles2D` approach from the old
  BookComplete screen).
- Both **fade away on their own** after a few seconds. Nothing persists,
  nothing needs dismissing, and the celebration never blocks input —
  painting, pan/zoom, navigation and the toolbar all keep working under it.
- The existing rules around *when* it fires are unchanged: the palette's
  completion threshold (§1), once per completion (sticky — re-painting a complete page or
  restoring one from a save must not re-fire it), and the page-flip ceremony
  still rewards the forward step off a page completed this visit (BL-4/BL-10).

## 3. Technical architecture

### 3.1 The vector mapping (per-page data)

Produced offline by the **mapping pipeline** (§4), shipped with the page art. Two artifacts per page:

**Display vs mask (BL-9, amended by BL-12).** Every page has one **display image** — the art the player sees, with paint appearing beneath its line work — and an **optional masking image**: separate line art that decides where paint may go. When a page has a mask, the mask is the pipeline's input **and is also rendered at runtime** as a permanent layer under the display image (§3.2, BL-12) — so the pipeline exports a third artifact, **`<page>_mask.png`** (the mask resampled to the display image's resolution), which is what ships and what `PageDef.mask_image_path` points to. The artist's print-size original still stays out of the build (behind `source/` `.gdignore`); its provenance is the regions JSON's `mask_image` field. When a page has no mask, the display image is its own mapping source and no mask layer is drawn. Either way the mapping artifacts below are generated at, and named after, the **display** page.

1. **`<page>_regions.json`** — vector data:
   ```json
   {
     "version": 1,
     "source_image": "page_01.png",
     "mask_image": "coyote_outline_source.png",
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
   `source_image` names the display page the artifacts belong to; `mask_image` is present only when the regions were traced from a separate masking image, and exists so a page's mapping is reproducible from the JSON alone. `outline`/`holes` are polygons in image pixel space (marching-squares traced, simplified); vertices are pixel-corner coordinates, while `centroid` is a pixel index. `centroid` is snapped to a pixel the region actually owns (an area-weighted mean can land inside a hole — useless as a tap-hint marker). `area_px` counts ID-map pixels (post line-dilation), making the ID map and JSON agree exactly.
2. **`<page>_idmap.png`** — a lossless **region ID map**: same dimensions as the display image, every pixel of region *N* has the flat color encoding *N* (`#000000` reserved: lines / not paintable). This is the runtime workhorse.

**Runtime roles:**
- **Hit-test (press → region id):** sample the ID map pixel at the press point (fast, exact, handles holes for free). The JSON polygons are the authored/portable representation and serve editor tooling, debug overlays, and centroid/area queries (e.g. completion, "tap hint" markers).
- **Paint constraint:** shader-based mask — see §3.2.

### 3.2 Constrained painting (performance-critical)

Do **not** CPU-paint pixels with per-pixel region checks on mobile. Use the GPU:

- The paint surface is a **`SubViewport`** the size of the page image; strokes are drawn into it (stamped brush quads along the drag path, interpolated so fast drags leave no gaps).
- The brush material's **shader samples the ID-map texture** and `discard`s any fragment whose ID-map color ≠ the locked region's `id_color`. The stroke geometry can freely cross lines; the shader clips it to the region.
- Scene layering (back → front): paper background → SubViewport paint texture → **mask texture when the page has one** (BL-12 — its outlines stay visible over the paint as permanent region guides) → display/line-art texture (lines on top, transparent elsewhere).
- The ID map **must** stay lossless end-to-end or region IDs bleed at edges. In Godot 4 that means: `.import` keeps `compress/mode=0`, `mipmaps/generate=false`, **and `detect_3d/compress_to=0`** (the default `1` silently re-imports as VRAM-compressed if the texture is ever seen in a 3D context). Texture *filtering* is not an import flag — set `TEXTURE_FILTER_NEAREST` on the node/material that samples the ID map.

Per-region **coverage tracking** for completion: count painted pixels per region. Cheap approach: on stroke end, sample the SubViewport texture at a sparse grid of points per region (precomputed from the polygons) rather than reading back full images every frame. Threshold from the palette (§1).

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
    screens/book_select.tscn
    screens/coloring_page.tscn   # page view + palette + toolbar
    components/palette_child.tscn    # the crayon row — the one palette (BL-20)
    components/page_view.tscn        # SubViewport painting stack, pan/zoom
    components/page_flip.tscn        # flip transition
  scripts/                   # mirrors scenes/; snake_case.gd
  resources/
    books/<book_name>/book.tres      # BookDef: title, cover, ordered page list
                                     #   (dev/editor fixtures only — release exports
                                     #    exclude res:// books; shipped builds get every
                                     #    book from the server, BL-25)
    books/<book_name>/pages/         # PageDef .tres per page
    palettes/child_palette.tres (+ palettes/sets/*.tres — one per crayon box,
                                     #    BL-23; since BL-35 each names a FINISH and
                                     #    inherits the palette's own lineup)
  assets/
    books/<book_name>/page_01.png / page_01_idmap.png / page_01_regions.json
                                     #   (dev fixtures — excluded from release exports
                                     #    like resources/books, BL-25)
  autoload/
    game_state.gd            # current book/page, save/load progress
  tools/
    generate_region_map.gd   # the mapping pipeline (§4) — dev-only, headless
```

Custom `Resource` types (`class_name`): `BookDef`, `PageDef` (display name + paths to the display image, the optional mask, the idmap and the regions JSON), `PaletteDef` (colors, brush sizes, completion threshold). Data in `.tres`, logic in nodes.

One autoload: `GameState`. Screens communicate upward via signals; `main.tscn` swaps screens and injects dependencies (e.g. hands `PageDef` + `PaletteDef` to the coloring screen).

### 3.5 Mobile considerations

- **Renderer: Mobile** (`rendering/renderer/rendering_method="mobile"`, Vulkan) — decided in M6, evaluated empirically on the dev box (RTX 5060, Godot 4.5.1) rather than from documentation. This is a pure 2D game, so the deciding factor was not raster performance (all three renderers draw a handful of quads and one `canvas_item` shader without breaking a sweat) but **API availability**:
  - Forward+ and Mobile are both Vulkan and both expose a `RenderingDevice`, so `RenderingServer.texture_get_rd_texture()` → `RenderingDevice.texture_get_data_async()` works — that is the asynchronous paint-layer readback the coloring loop depends on (§3.2).
  - **Compatibility (`gl_compatibility`) is OpenGL and `RenderingServer.get_rendering_device()` returns null**, so there is no async readback at all. Every coverage update would fall back to the blocking one, which measures **350–530 ms** under the default FIFO v-sync. That disqualifies it as the shipping renderer.
  - Between Forward+ and Mobile, Mobile wins on cost: it is the tile-GPU-oriented pipeline (single-pass forward, no clustered-lighting/decal/SDFGI machinery to set up per frame), which means less bandwidth and less battery for output that is pixel-identical here. All five smoke tests pass under it on Windows.
  - Compatibility remains the fallback for a device with no Vulkan 1.0 driver. The code degrades rather than breaks: `AsyncReadback.request()` returns false and the caller uses the synchronous readback.
- Textures: page art up to 2048×2048; keep ID maps lossless (VRAM-uncompressed) — they are correctness-critical. `rendering/textures/vram_compression/import_etc2_astc=true` gives ETC2/ASTC for everything else.
- Touch targets ≥ 48 px logical (the crayon palette's controls use 64+, the settings gear 72); UI uses anchors/containers for portrait/landscape, and `scripts/components/safe_area.gd` wraps the shell in notch-safe margins.
- Window stretch mode `canvas_items`, aspect `expand`. **Consequence worth knowing**: with the 1152×648 base viewport, a portrait window never narrows the logical canvas below 1152 — it grows the *height* instead (a 720×1280 window becomes a 1152×2048 canvas). Portrait layouts therefore key off **aspect ratio**, not width.
- Orientation: `display/window/handheld/orientation=6` (SENSOR) — portrait and landscape both allowed.
- Android export: `godot/export_presets.cfg`, preset `Android`. See [ANDROID.md](ANDROID.md).

## 4. Mapping pipeline (dev tool, not shipped gameplay code)

`godot/tools/generate_region_map.gd` — run headless:

```
<godot_exe> --headless --path godot --script tools/generate_region_map.gd -- assets/books/<book>/page_01.png
```

The positional argument is the **mapping source**. A page mapped from a separate masking image passes the mask there and names its display art with `--display`, which is where the artifacts are written (and whose resolution the mask is resampled to, since the artist's mask arrives at print size):

```
... -- assets/books/coyote/source/coyote_outline_source.png --display assets/books/coyote/page_01.png
```

Steps:
1. Load the line-art PNG; binarize: line pixels = alpha/darkness above threshold (configurable).
2. **Flood-fill segmentation** of non-line pixels → connected regions; discard specks below a minimum area (noise).
3. Assign each region an id and an `id_color` (encode id in RGB, e.g. `id = R<<16|G<<8|B`); write **`_idmap.png`**.
4. **Marching squares** around each region → outline (+ holes), simplify (Ramer–Douglas–Peucker, tolerance configurable); compute centroid & area; write **`_regions.json`** (§3.1 schema). On a `--display` run also write **`_mask.png`** — the mask as resampled in step 1, which is the runtime layer (§3.1/§3.2, BL-12) and costs one extra PNG encode because that image already exists.
5. Print a summary (region count, dropped specks, min/max area) and fail loudly on: unclosed line gaps producing one giant region, or zero regions.

Also provide a **debug overlay** toggle in `page_view.tscn` that tints regions from the JSON polygons — the fastest way to verify a page's mapping in-game.

## 5. Implementation milestones (historical — M1–M6 shipped; the mode split M3/M5 built was later removed by BL-20)

1. **M1 — Mapping pipeline**: `generate_region_map.gd` + one hand-made test page (simple shapes). Verify JSON + ID map outputs. *Everything else depends on this.*
2. **M2 — Page view & constrained painting**: `page_view.tscn`, SubViewport stack, brush shader with ID-map clipping, stroke lifecycle, pan/zoom. Test with M1's page.
3. **M3 — Palettes & modes**: `PaletteDef`, child crayon row, adult swatches, brush sizes, `GameState.mode`.
4. **M4 — Books, pages, completion & flip**: `BookDef`/`PageDef`, coverage tracking, completion thresholds, page-flip transition, book select screen.
5. **M5 — Shell & persistence**: title, mode select, save/load progress, settings.
6. **M6 — Mobile pass**: renderer evaluation (§3.5), async paint readback, portrait/safe-area layout pass, page navigation, the first real art book (`coyote`), Android export preset. Device profiling still pending — no Android hardware or 4.5.1 export templates on the dev box; see [ANDROID.md](ANDROID.md).

Each milestone must end with the project running clean (no errors in debug output) via the godot-mcp `run_project` → `get_debug_output` loop.
