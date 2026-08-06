# Backlog — Issues & Feature Requests

Logged 2026-08-06 from playtest feedback. Status: `open` → `in-progress` → `done`.

## Issues

### BL-1: Default canvas zoom is too tight — `done`
The drawing canvas opens at a zoom level where the page edges are hard to reach.
By default the canvas should start slightly zoomed **out**, leaving a comfortable
margin around the page so players can easily color regions at the edges.
- Affected: `scripts/components/page_view.gd`
- Done: new `PageView.default_zoom_factor` (0.85) frames the page at 85% of the
  fit zoom on load and on every re-fit. Only the OPENING framing changed — the
  zoom limits are still anchored to the true fit, so pinch/wheel zoom and pan
  behave exactly as before and the player can still zoom further out.

### BL-2: Color picker should be slide-to-select — `done`
Swatches/crayons currently select on press. They should support slide-to-select:
the player drags across the palette and the highlighted/selected color follows
their finger, committing as they slide (standard kid-app palette behavior).
- Affected: `scripts/components/palette_slide_input.gd` (new),
  `palette_child.gd`, `palette_adult.gd`
- Done: the crayons/swatches switched to `ACTION_MODE_BUTTON_PRESS` so the first
  pick lands as the finger does; the drag half lives in the shared
  `PaletteSlideInput` helper, which both palettes feed their `_input()` events.
  It hit-tests the buttons in viewport space (one touch code path, like
  `PageView`) and marks claimed drags handled so the swatch scroller cannot
  drag-scroll mid-slide. `swatch_button.gd` / `crayon_button.gd` were untouched.

### BL-3: Brush size should be a slider bar — `done`
Replace the current brush-size dot buttons with a slide bar (continuous or
stepped slider) for picking brush size.
- Affected: `scripts/components/brush_size_slider.gd` (new, replaces the deleted
  `brush_size_dot.gd`), `palette_adult.gd`
- Done: one custom-drawn `BrushSizeSlider` (wedge track, tick per stop, knob
  drawn at the diameter it selects). Stepped over the palette's authored
  `brush_sizes`, so it reports an INDEX and the existing
  palette -> `brush_size_picked` -> `ColoringPage` -> `PageView.brush_size`
  chain is unchanged. The shared palette contract's `get_brush_size_buttons()`
  became `get_brush_size_controls()`.

### BL-4: Page flip animation needs major improvement; no auto-flip — `done`
Two parts:
1. The page flip animation quality must be greatly improved (real page-turn
   feel: curl/shadow/easing, not a simple slide/fade).
2. Completing a page must **not** automatically flip to the next page. Show a
   completion celebration/state and let the player flip when they choose.
- Affected: `scenes/components/page_curl.gdshader` (new),
  `scripts/components/page_flip.gd`, `scenes/components/page_flip.tscn`,
  `scripts/screens/coloring_page.gd`, `scenes/screens/coloring_page.tscn`
- Done: the scale/rotate/darken fake became a real curl in one fragment shader.
  The sheet is peeled along a *leaning* fold line: a lit crease of radius
  `curl_radius` rolls across the page, the paper folds back over itself showing
  its reverse (with the printed side faintly bleeding through), and a soft shadow
  travels ahead of the fold onto whatever is revealed. One full-screen quad, two
  texture fetches at worst, no render target — the same cost as the TextureRect
  stack it replaces, and it runs the same on Mobile/Vulkan and on the web export.
  The whole transition is one CUBIC/IN_OUT tween on one `progress` uniform, and
  `progress == 0` is a pixel-exact pass-through, which is what keeps
  `prepare()`'s hand-off invisible. `PageFlip`'s public API is unchanged.
  Completion no longer navigates: `_on_coverage_page_completed()` saves, then
  raises a **persistent** "Page complete!" state and stops. The next-page arrow
  unlocks (`can_go_to_page()` already allowed exactly one page forward off a
  finished page) and pressing it is what plays the flip — `go_to_page()` gives
  the ceremony to that one jump and keeps the instant swap for every other. The
  state clears as soon as the player touches the page again. The **last** page
  still reports `book_completed` immediately: there is no next page to choose to
  turn to, and the book-complete screen is the reward.

### BL-5: Completion threshold too loose — `done`
Pages register as "complete" while too much white remains. Tighten the
per-region / per-page coverage threshold so a completed page actually looks
colored in.
- Affected: `scripts/components/coverage_tracker.gd`,
  `resources/palettes/child_palette.tres`, `adult_palette.tres`,
  `scripts/resources/palette_def.gd`
- Done: three named constants, no magic numbers, and the per-mode values stay
  authored data (coloring-mechanics: thresholds come from the `PaletteDef`, never
  from code).
  * `CoverageTracker.COVERED_ALPHA` 128 → **160**: a sample no longer counts as
    coloured at half opacity, which is exactly the pixel that still reads as pale
    paper. The dab is fully opaque out to `hardness` of its radius, so anything
    actually swept over is far above 160.
  * `CoverageTracker.MIN_REGION_THRESHOLD` = **0.85**, a hard floor
    `set_threshold()` clamps every injected value against, so no authored palette
    can ever call a mostly-blank region finished. `PaletteDef.validate()` reports
    a threshold below it rather than letting it be silently raised.
  * Shipped thresholds: child **0.70 → 0.90**, adult **0.92 → 0.96**. Child stays
    the forgiving mode (a fringe of paper is fine, a patch of it is not); adult
    is near-complete fill. The page-level rule is unchanged and already strict —
    a page is complete only when *every* region is.

### BL-6: Auto-save at intervals + manual save button — `done`
The game should auto-save progress at regular intervals (and on key events like
leaving a page), plus expose a manual save button in the UI.
- Affected: `autoload/game_state.gd`, `scripts/screens/coloring_page.gd`,
  `scenes/screens/coloring_page.tscn`, `scripts/main.gd`
- Done: `GameState.AUTOSAVE_INTERVAL_SECONDS` = **45 s** (top of the 30-60 s band:
  a page takes a child minutes, so 45 s bounds a crash to under a minute of
  colouring while keeping the readback + PNG write rare). A `Timer` on the
  autoload emits `autosave_due`; `GameState` writes its own JSON, and the open
  `ColoringPage` — the only thing that can reach the paint layer — writes the
  pixels. It **never reads the paint layer mid-stroke**: a save asked for while a
  stroke is down (or while a coverage readback is in flight) is remembered and
  runs from `stroke_ended`. A `_paint_dirty` flag means an idle page costs
  nothing at all. Key events: the M5/M6 save points are unchanged (page complete,
  leaving the book, navigating, quit, `APPLICATION_PAUSED`), plus
  `NOTIFICATION_APPLICATION_FOCUS_OUT` in `main.gd` (alt-tab / the browser tab
  losing focus) which takes the async path because the app still has frames.
  The manual **Save** button lives in the coloring page's toolbar, not in the
  settings panel: the settings gear is deliberately hidden while a book is open,
  so a Save button there would be unreachable exactly when it is wanted. It shows
  a brief "Saved!" toast (and "Saving…" if it had to wait out a stroke).

### BL-7: Start-over button per page — `done`
Any page should have a button to reset it: clears all paint/progress for that
page only (with a confirm step so kids don't wipe work accidentally).
- Affected: `autoload/game_state.gd`, `scripts/screens/coloring_page.gd`,
  `scenes/screens/coloring_page.tscn`
- Done: a **Start over** button next to Save in the toolbar. Confirming is a
  two-button in-game overlay ("Yes, start over" / "Keep colouring", plus a scrim
  that cancels) modelled on the settings panel's erase guard — never an OS or
  JavaScript modal, which is the one thing that would not survive the web export.
  `ColoringPage.restart_current_page()` bumps the page generation (so a coverage
  readback taken from the paint we are about to wipe cannot be folded into the
  new tracker), calls `PageView.clear_paint()`, builds a fresh `CoverageTracker`
  and calls the new `GameState.erase_page_progress(book, page_index)`, which
  deletes that page's PNG and puts its status back to `untouched`. That is the
  ONE place a status moves backwards — `mark_page_status()` still refuses
  downgrades — and the rest of the book, including the cursor and every other
  page, is untouched.

### BL-8: DLC support + backend server (design) — `design done` (see docs/DLC_SERVER.md; implementation later)
Longer-term: introduce DLC coloring-book packs. Backed by a (most likely
Laravel) server handling:
- user accounts and cloud-synced game saves
- DLC entitlement/delivery
- uploading and managing coloring books and pages (admin tooling that feeds
  the region-mapping pipeline)
First step is a design document; implementation comes later.
- Affected: new `docs/DLC_SERVER.md`; eventually a separate Laravel project

### BL-9: Coyote book is wrongly split into two pages — `done`
The two coyote source images were imported as two separate pages. Intended
behavior: they are **one page** —
- `coyote_outline_source.png` is the **line-masking** image: used to generate
  the region ID map / polygons, but **hidden** at runtime.
- `coyote_detail_source.png` is the **visible** image: the detailed art the
  player sees, with paint appearing beneath its line work.
Page/book data needs to support a separate "mask source" vs "display" image.

General rule (clarified 2026-08-06): **every** supplied page in a coloring book
contains the detailed (visible) image, with an **optional** masking image. When
a mask image is present it drives region-map generation and stays hidden at
runtime; when absent, the detail image itself is the mapping source.
- Affected: `scripts/resources/page_def.gd`, `book_def.gd`,
  `scripts/components/paint_canvas.gd`, `page_view.gd`,
  `tools/generate_region_map.gd`, `assets/books/coyote/*`
- Done: `PageDef.base_image_path` became **`display_image_path`** (required) and
  gained an optional **`mask_image_path`**, plus `has_mask()` /
  `get_mapping_source_path()`. The mask is build input and provenance, never a
  runtime asset: `validate()` deliberately does NOT require it to exist, because
  a page must stay valid in a build that ships none of the artist's source art
  (docs/DLC_SERVER.md §7.2). A page with no mask — every test-book page — is its
  own mapping source and behaves exactly as before.
  The pipeline gained **`--display <page.png>`**: the positional argument stays
  "the image whose lines decide where paint may go", and with `--display` that
  image is a mask while the artifacts are written next to the page art and the
  mask is resampled to the page's resolution (the artist's mask is print-size;
  mismatched *aspect* hard-fails instead of squashing). The regions JSON records
  the mask in an additive `mask_image` field so a mapping is reproducible from
  the JSON alone.
  Runtime is **unchanged by design**: `ColoringPage` hands `PageView` the display
  image, `PageView` renders it over the paint layer, and the clip is still the
  ID map in `brush.gdshader`. The mask is never loaded — it is not even imported
  (it lives behind the `source/` `.gdignore`), which the mobile smoke asserts.
  This does not contradict the future `load_page_textures()` primitive sketched
  in DLC_SERVER.md §8.1: that still takes one visible texture + one ID map.
  The coyote book is now **one page**: `page_01.png` is the detail art,
  `page_01_idmap.png` / `page_01_regions.json` were regenerated headless from
  `source/coyote_outline_source.png` (2 regions — coyote + paper), and the bogus
  page 2 (`.tres`, PNG, idmap, regions, `.import`s) is gone. Stale saves cannot
  bite: every reader already clamped against `BookDef.has_page()`, and
  `GameState._entry_for()` now trims an entry — and deletes the orphaned paint
  PNGs — when a book gets shorter, which is the general case of "a re-authored or
  DLC-updated book lost a page".
