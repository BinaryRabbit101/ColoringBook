# Backlog Archive — completed entries

Moved out of [BACKLOG.md](BACKLOG.md) on 2026-08-07 to keep the working backlog
lean. Every completed entry keeps its full done-note: these record the decisions,
gotchas and smoke-count history that implementing agents rely on. Do not trim them.
Ordered by entry number (BL-8, the DLC umbrella, stays in BACKLOG.md — its Phase 6
is still open).

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

### BL-10: Free play — no completion requirement + coloring lock — `done`
Full design: DESIGN.md §2.1. Completing a page must never be a requirement for
anything. Four parts:
1. **Free page choice**: every page of an open book is always reachable via
   prev/next — drop the "reached pages + one forward when complete" gating in
   `ColoringPage.can_go_to_page()` / `furthest_reached_index()`. The BL-4 flip
   ceremony stays reserved for the forward step off a just-finished page; all
   other jumps keep the instant swap.
2. **Color forever / revisit**: a complete page stays fully paintable, in the
   same sitting and after reopening. Completion stays sticky and must not
   re-celebrate on later strokes (already true today — keep it that way, and
   keep coverage/save behavior working on post-complete strokes).
3. **Book completion is chosen**: the last page no longer reports
   `book_completed` immediately on completion — it shows the same persistent
   complete state as any page, and `book_completed` fires only when the player
   presses forward off the completed last page.
4. **Coloring lock**: per-page padlock toggle in the coloring toolbar,
   persisted in the save (`pages[]` entry gains a `locked` flag). Locked =
   no stroke starts, Start over disabled; pan/zoom, save, navigation, palette
   and mode switching unaffected; tapping a locked page gives lightweight
   feedback (padlock wiggle). Single-tap unlock, no confirm.
- Affected: `scripts/screens/coloring_page.gd`, `scenes/screens/coloring_page.tscn`,
  `scripts/components/page_view.gd` (stroke-start gate),
  `scripts/components/padlock_button.gd` (new), `autoload/game_state.gd`
  (lock persistence), `scripts/main.gd` (book-complete handoff), dev smokes,
  `.claude/skills/coloring-mechanics/SKILL.md` (update the completion/navigation
  facts once implemented).
- Done, part by part:
  1. **Free page choice.** `ColoringPage.can_go_to_page()` is now the whole rule:
     *is that a page of this book, and not the one already open*. The M6
     "reached pages + one forward when complete" gate and its
     `furthest_reached_index()` helper are **gone** — nothing else used them, and
     a helper that exists only to gate is worse than no helper. The BL-4 ceremony
     was NARROWED rather than kept as-is: `go_to_page()` plays the flip when the
     step is forward-by-one off a page completed **during this visit**
     (`_completed_this_visit`), so re-opening an already-finished page and
     stepping forward is browsing (instant), while finishing a page and stepping
     forward is still the reward. Without that narrowing, free navigation would
     have sprinkled the 0.8 s curl over ordinary page-flicking.
  2. **Colour forever.** Nothing had to be added to keep painting a complete page
     working — the tracker is monotonic, statuses are sticky and
     `CoverageTracker.page_completed` fires once — so the work here was proving
     it and not breaking it: post-completion strokes still mark the page dirty,
     still run a coverage cycle, still save, and cannot re-celebrate. The
     smokes now assert exactly that on both a page finished in the sitting and a
     page restored already complete.
  3. **Book completion is chosen.** `_on_coverage_page_completed()` lost its
     last-page branch: the last page celebrates and stays put like any other.
     `is_finish_book_gesture()` (last page + complete) turns the forward arrow
     into the new `finish_book()`, which saves and emits `book_completed`.
     **Decision: no flip on that gesture** — a curl peels back to reveal what is
     underneath, and there is nothing underneath the last page; `main.gd` already
     cross-fades to `BookComplete` exactly as it does for every other screen, so
     the one transition the player sees is the one actually going somewhere.
  4. **The coloring lock.** One additive property on the frozen `PageView` —
     `painting_enabled`, checked at the top of `begin_stroke()` (the single
     stroke-start in the component, so one gate covers touch, mouse and tests)
     — plus a `paint_blocked(page_position)` signal, because a page that silently
     ignores a child is a page a child thinks is broken. Setting it false cancels
     a stroke already down, so it is safe to flip mid-drag. `ColoringPage` owns
     the state: the toolbar's `PadlockButton` (new, drawn from primitives like
     `Main.GearButton` — the shell still ships no icon assets) toggles it,
     `paint_blocked` shakes that padlock, and Start over is disabled while
     locked (`restart_current_page()` refuses too, not just the button).
     Everything else — pan/zoom, two-finger gestures, Save, navigation, palette,
     mode switching — is deliberately untouched.
  - **Save format.** A `pages[]` entry widened from a bare status string to
    `{"status": …, "locked": …}`. `SAVE_VERSION` deliberately did **not** move:
    the change is additive both ways. `GameState._to_page_entry()` normalises a
    bare string (pre-BL-10 save → every page unlocked) or a missing `locked` key,
    `_page_slot()` upgrades a slot in place the first time it is written, and the
    entry is re-built (not `duplicate()`d) on the way out because the slots are
    dictionaries now and a shallow copy would hand `JSON.stringify` the live ones.
    The BL-9 shrinking/trim path in `_entry_for()` needed no change — it moves
    whole slots. The lock is written with `save_now()` the instant it is set (a
    lock that survives only until the next crash is not a lock) and is
    independent of progress: `erase_page_progress()` leaves it alone.
  - **Gotcha:** a new `class_name` script is invisible to a CLI run until the
    project is rescanned — `<godot_exe> --path godot --headless --import` after
    adding `padlock_button.gd`, or `PadlockButton` fails to parse.
  - Smokes: **paint 25 → 33** (new check 8: `painting_enabled` refuses the press,
    reports it, keeps the paint already down, cancels mid-stroke), **flow 104 →
    119** (free choice from the first frame; the last page no longer ends the
    book, stays paintable, and `book_completed` waits for the forward press),
    **shell 111 → 141** (new check c3 for the padlock end to end + the lock on
    disk; check b reads the new entry shape; check d presses forward to reach
    BookComplete; check h now doubles as the pre-BL-10 save-format test),
    **mobile 113 → 130** (check d rebuilt: free jump into an untouched page, the
    flip only off a page just finished, painting on a completed page without
    re-celebrating, and the lock following the PAGE across a navigation).

### BL-11: Transient on-page celebration; remove BookComplete — `done`
Logged 2026-08-06. Full design: DESIGN.md §2.2. Replace both completion
presentations with ONE transient on-page celebration:
1. **Kill the persistent "Page complete!" state** (BL-4's `Celebration` overlay
   in `ColoringPage`). In its place: completing a page shows a **random**
   congratulatory message (authored pool — "This looks fantastic!",
   "Beautiful work!", "So colorful!", …) **above the page**, together with a
   confetti burst, and both **fade away over time** on their own (no tap to
   dismiss needed, nothing persists). The celebration is pure presentation:
   it must not block painting, pan/zoom, navigation, or any toolbar control,
   and the existing no-re-fire rules (sticky completion, `_pre_completed`,
   once-per-tracker) are unchanged.
2. **Delete the BookComplete screen** (`scenes/screens/book_complete.tscn` +
   `scripts/screens/book_complete.gd`) and the whole book-finish gesture with
   it: `ColoringPage.book_completed`, `finish_book()`,
   `is_finish_book_gesture()`, and `main.gd`'s BookComplete state. The last
   page has **no special case** — it celebrates like any page, its forward
   arrow is simply disabled (there is no next page), and the player leaves the
   book via **Back**, the same as always. `GameState.finish_book()` /
   `book_finished` lose their only caller — remove or leave dormant, whichever
   falls out cleaner.
3. **Keep** the BL-4/BL-10 flip ceremony (forward step off a page completed
   this visit — `_completed_this_visit` stays), all save points (page complete
   still saves), and the padlock.
- The confetti can be lifted from BookComplete before deleting it: the
  palette-driven `CPUParticles2D` (flat crayon-colored scraps via a CONSTANT
  `color_initial_ramp`) is exactly the right look and already asset-free.
- Affected: `scripts/screens/coloring_page.gd`, `scenes/screens/coloring_page.tscn`,
  `scripts/main.gd`, delete `book_complete.{tscn,gd}`, `autoload/game_state.gd`
  (dead `finish_book`), dev smokes (flow/shell/mobile assert the BookComplete
  flow and the persistent state today),
  `.claude/skills/coloring-mechanics/SKILL.md` (after implementation).
- Done: the `Celebration` overlay is now a `Label` above the page plus a
  one-shot `CPUParticles2D`, and a single tween runs the whole thing —
  `CELEBRATION_FADE_IN` 0.28 s → `CELEBRATION_HOLD` 2.3 s → `CELEBRATION_FADE_OUT`
  1.2 s → a callback that hides it. Roughly four seconds, start to finish, with
  nothing to dismiss. The message comes from `CELEBRATION_MESSAGES` (eight
  authored lines) picked at random and never the same twice running — a repeat
  reads like a bug, not like variety.
  The confetti was lifted from `book_complete.gd` before deleting it: one
  `CPUParticles2D`, no art assets, scraps coloured from the CHILD palette through
  a CONSTANT-interpolation `color_initial_ramp` (flat crayon colours, not a
  blend). The only change is `one_shot` + `explosiveness`, so it is a burst
  rather than a screen that rains forever.
  **It blocks nothing**: the overlay is `MOUSE_FILTER_IGNORE`, nothing is
  disabled while it is up, and — deliberately — a stroke no longer dismisses it.
  BL-4's persistent headline had to get out of the player's way; three seconds of
  confetti does not, and "painting keeps working under it" is easier to believe
  when the celebration does not react to painting at all.
  **The last page lost its last special case.** `book_completed`,
  `finish_book()`, `is_finish_book_gesture()`, `main.gd`'s BookComplete
  state/scene/handlers and `GameState.finish_book()` / `book_finished` are all
  gone; `_refresh_nav()` disables the forward arrow on the last page like any
  other end of a list, and `back_requested` is the only signal `ColoringPage`
  still raises. `GameState.erase_book_progress()` outlived its only caller
  (BookComplete's "Color again") and stays — it is the API a shelf-side "start
  this book again" will want, and the shell smoke drives it directly now.
  Untouched, as required: sticky completion, `_pre_completed`, the
  once-per-tracker `page_completed`, `_completed_this_visit` and its flip, and
  every save point.
- Smokes: **flow 119 → 126**, **shell 141 → 147**, **mobile 130 → 139** (that
  one also carries BL-12). New cases: the celebration's message really comes from
  the pool, the confetti burst is palette-coloured and emitting, the overlay
  cannot intercept a touch, a stroke still starts while it is on screen, and it
  fades away with nothing dismissing it — then, on the last page, the forward
  arrow is disabled and Back is the exit. Shell check d finishes both pages and
  leaves by Back, wipes the book with `erase_book_progress()` and reopens it
  clean, which is what "Color again" used to cover.

### BL-12: Draw the optional mask as a layer under the detail image — `done`
Logged 2026-08-06. Reverses the BL-9 "mask is never loaded or rendered" rule.
When a page has a masking image, render it as a **permanent layer** in the page
stack, directly **under the detail image and above the paint**:

    paper → paint SubViewport → mask (when present) → detail image

The mask's outlines stay visible on top of the paint at all times — region
guides the detail art may lack. A page with no mask renders exactly as today.
- **The mask becomes a runtime asset.** The artist's print-size original stays
  behind `source/` `.gdignore`; what ships is a **third pipeline artifact**:
  `tools/generate_region_map.gd --display` additionally writes
  `<page>_mask.png` — the mask resampled to the display image's resolution
  (it already computes exactly that image for mapping) — next to the idmap.
  `PageDef.mask_image_path` now points at that shipped artifact, and
  `PageDef.validate()` **requires it to exist when set** (it is no longer
  provenance-only). Provenance of the original stays in the regions JSON's
  `mask_image` field, unchanged.
- The mobile smoke's "mask is not imported" assertion (BL-9) inverts: the
  shipped mask artifact must be imported; the `source/` originals must not.
- Regenerate the coyote artifacts (`--display` run) and repoint
  `page_01.tres`'s `mask_image_path` at the new artifact.
- DLC packs ship the artifact too — DLC_SERVER.md §7/§8.1 updated alongside
  this entry (pack layout gains `page_NN_mask.png`; the future
  `load_page_textures()` primitive gains an optional mask texture).
- Affected: `scripts/components/page_view.gd`, `scenes/components/page_view.tscn`,
  `scripts/resources/page_def.gd`, `tools/generate_region_map.gd`,
  `scripts/screens/coloring_page.gd` (hand the mask path through),
  `assets/books/coyote/*`, `resources/books/coyote/pages/page_01.tres`,
  dev smokes, `docs/DESIGN.md` §3.1–3.2, `docs/DLC_SERVER.md`,
  `.claude/skills/coloring-mechanics/SKILL.md` (after implementation).
- Done: `page_view.tscn` gained a `MaskSprite` between `PaintSprite` and
  `LineArtSprite`, and `load_page()` a fourth, optional `mask_path`. The mask
  shares the LINE ART material (`line_art.gdshader`, `white_to_alpha`) because it
  is the same KIND of thing — ink over the paint — and the coyote's mask is white
  on transparent exactly like its display art. A page with no mask leaves the
  sprite hidden and textureless, which is byte-for-byte the pre-BL-12 render; a
  mask whose size does not match the page is REFUSED with a warning rather than
  stretched, because guides drawn in the wrong place are worse than none.
  `PageView` grew `has_mask_layer()` / `get_mask_texture()` for the smokes and
  nothing else — the clip is still the ID map, and the stroke lifecycle, the
  shader and the coverage path were not touched.
  The pipeline writes the third artifact from the image it already resampled for
  mapping (`_write_mask()`, `--display` runs only), so it costs one PNG encode.
  Re-running the coyote page reproduced `page_01_idmap.png` and
  `page_01_regions.json` byte-identically and added `page_01_mask.png`
  (1804×2048, 386 KB); `page_01.tres` now points `mask_image_path` at it instead
  of into `source/`, and `PageDef.validate()` requires a named mask to exist —
  pointing it back at the artist's original is now a hard validation failure,
  which the mobile smoke asserts. The regions JSON's `mask_image` still names the
  print-size original, so provenance is unchanged.
- Smokes: folded into **mobile 130 → 139** with BL-11. Check c2 inverted:
  the shipped artifact IS imported and is the display image's size, the `source/`
  original is on disk but NOT imported, a page naming an unimported mask fails
  `validate()`, `PageView` draws the layer, its texture is the page's own mask,
  and its node index really is between the paint and the display art — with the
  test book proving a maskless page still draws no layer at all.

### BL-13: App-branded splash screen & loading bar — `done`
Logged 2026-08-06. Replace the stock boot/loading presentation with something
appropriate to the app and elegant. Today the desktop/mobile boot shows the
default **Godot splash**, and the web export ships the default HTML shell
(Godot logo + generic progress bar). Two pieces:
1. **Boot splash** (`application/boot_splash/image` + `bg_color` in
   `project.godot`): a static image styled like the shell — the title screen's
   warm paper and crayon look, no new art-asset dependencies beyond the splash
   PNG itself (author it from the same palette/style the shell draws
   procedurally). **The Godot engine logo remains presented on the loading
   splash** (decision 2026-08-06) — attribution-style, e.g. a modest
   "made with Godot" mark, not the centerpiece. (The logo is CC-BY-4.0;
   attribution use is fine.)
2. **Web loading screen** (`html/custom_html_shell` in the Web export preset):
   a custom shell whose page matches the splash (same paper background), with
   an elegant app-style progress indicator — e.g. a crayon stroke filling in —
   instead of the generic bar, and the Godot logo retained as in (1). Plain
   HTML/CSS/JS in the shell template; no external requests, no JS modals.
3. **No flash between stages**: the web page background, the boot splash
   `bg_color`, and the splash image's own background must be the same color,
   so shell → splash → TitleScreen reads as one continuous load.
- Adjacent but NOT in scope: `config/icon` is also still the stock Godot icon;
  replacing the app icon can ride along later. (It did — see the last
  done-note.)
- Affected: `godot/project.godot`, `godot/export_presets.cfg` (Web preset),
  new splash image asset + custom HTML shell file (suggest
  `godot/assets/splash/`), redeploy per docs web-deploy notes.
- Done: **one colour everywhere** — `#1f1c1a`, which was already `main.tscn`'s
  backdrop, is now `application/boot_splash/bg_color`, the splash artwork's own
  background and (via the shell's `$GODOT_SPLASH_COLOR`) the web page's
  background. Browser shell → engine splash → TitleScreen is one continuous
  colour with nothing flashing between the stages.
  **The splash is generated, not painted**: `scenes/dev/splash_render.tscn` +
  `scripts/dev/splash_render.gd` draw it from the same primitives and the same
  `child_palette.tres` colours `TitleScreen` uses (warm paper sheet, per-letter
  tilted crayon lettering with an ink outline, the wobbling scribble, a crayon
  shelf) and write `assets/splash/boot_splash.png` (1024×1024, square so it frames
  in both orientations). Re-run it after a palette change and the splash follows
  the app instead of drifting from it. The Godot logo sits along the bottom as
  "made with Godot", credit-sized (decision 2026-08-06).
  **Web shell**: `assets/splash/web_shell.html`, wired into the Web preset's
  `html/custom_html_shell`. It shows that same splash image — so the engine mark
  is on screen for the whole load and is never duplicated or restyled — over an
  inline-SVG progress indicator: a crayon rides the tip of a wobbling wax stroke
  that fills in across a palette gradient (`stroke-dashoffset` +
  `getPointAtLength`), sweeping instead of lying when no byte total is known yet.
  No external requests, no web font, no JS modal; failures land in an on-page
  panel, the same rule BL-7's in-game confirm follows. The engine-feature and
  service-worker branches are kept verbatim from the stock template — that logic
  is not ours to improvise.
  Verified by exporting the Web preset to a scratch directory (NOT deployed) and
  serving it locally with the wasm throttled: every `$GODOT_*` placeholder
  substitutes, the page background comes out `#1f1c1a`, the crayon draws its
  stroke as the bytes arrive, and it hands over to the title screen with a clean
  console.
- Done (**app icon**, the ride-along the scoping note allowed for): the splash
  generator no longer reads `config/icon`. That coupling was the whole risk —
  the attribution mark was the Godot logo only because the project icon still
  was, so pointing `config/icon` at the app's own picture would have quietly
  turned "made with Godot" into "made with ColoringBook". The engine mark is now
  its own asset, `assets/splash/godot_logo.svg` (a byte-for-byte copy of the
  retired stock `icon.svg`), and `splash_render.gd` reads it from there and only
  from there. Decoupled FIRST, before the icon was touched.
  The icon is **generated, not painted**, for the same reason the splash is:
  `tools/generate_app_icon.gd` reads `child_palette.tres` and emits
  `assets/icon/app_icon.svg` — the app's `#1f1c1a` backdrop as the tile, a warm
  sheet of paper on it, three wobbling wax strokes in the first three title
  colours and a crayon resting its tip on the stroke it just drew. Every shape
  is a rectangle, a polyline or a polygon, the same anatomy `TitleScreen` and
  `CrayonButton` draw, so the icon cannot drift from the shell and the project
  still ships no hand-made art for its own chrome.
  It emits **SVG** rather than rendering through a SubViewport, because an icon
  is looked at from 32 px to 1024 px and a vector re-rasterises crisply at all of
  them — which also means this generator, unlike the splash one, needs no window
  and runs headless. `--preview <path.png>` writes a 512/128/64/32 contact sheet
  outside the project, since the only question that decides an icon is whether it
  still reads once it is 32 px in a task bar; the dark tile is what keeps the
  silhouette there. The stock `icon.svg` is gone from the project root.
  Verified: re-running the splash generator reproduced `boot_splash.png` with the
  Godot robot still along its bottom edge, the project boots clean, and
  `flow_smoke` is 126/126 green.
- Still open: this deliberately did not redeploy the web build, and the
  per-platform export icons (Android launcher and adaptive layers) are still
  blank — they fall back to `config/icon`, which is now at least the right
  picture rather than the engine's.

### BL-14: One smaller and one larger brush size on the size slider — `done`
Logged 2026-08-06 from playtest. The adult size slider's range is too narrow:
add one size **below** the current smallest and one **above** the current
largest. Brush sizes are authored data (coloring-mechanics: diameters in
`PaletteDef.brush_sizes`, fed straight to `PageView.brush_size`), so this is
a data change plus layout verification:
- `adult_palette.tres` `brush_sizes`: `(16, 32, 56)` → `(8, 16, 32, 56, 96)`
  (suggested values — a true fine-detail tip, and a top size matching the
  child mode's 96 brush; adjust by feel in-game).
- `BrushSizeSlider` (BL-3) is stepped over the authored array and draws its
  knob at the diameter it selects — verify the wedge track, five ticks, and
  a 96 px knob still lay out sanely in the toolbar (cap the knob's *visual*
  size if it overflows; the reported diameter must stay 96).
- Child mode is untouched (single fixed brush, no slider).
- Affected: `resources/palettes/adult_palette.tres`,
  `scripts/components/brush_size_slider.gd` (only if the knob needs a visual
  cap), palette smoke if it asserts size counts.
- Done: it really was a data change. `brush_sizes` is now
  `(8, 16, 32, 56, 96)`; `default_brush_size` stays 32, which is still one of
  the stops and now sits in the MIDDLE of the range instead of at its top. Not
  one line of palette → `brush_size_picked` → `ColoringPage` →
  `PageView.brush_size` moved, because the slider was always stepped over the
  authored array and always reported an INDEX.
  The 96 px knob needed no capping: `BrushSizeSlider` never drew the knob at its
  diameter in the first place — the radius is interpolated across
  `MIN_KNOB_RADIUS`..`MAX_KNOB_RADIUS` (8..20 px) by where the stop sits in the
  palette's own range, so the widened range redistributes the same five drawn
  sizes over the same bar. The class doc now says so out loud ("the knob is a
  PROXY, not a ruler"), since "drawn at the diameter it selects" was the sentence
  that made a cap sound necessary.
  One real layout bug did surface: the biggest knob's selection ring reached
  26.5 px from the knob centre against 24 px of `SIDE_PADDING`, so the end stops
  bled 2.5 px out of the control — true before BL-14 too, just never measured.
  `SIDE_PADDING` is 28 now, the ring's offset and stroke are named constants, and
  `max_knob_extent()` is the arithmetic the palette smoke asserts against so the
  next person to fiddle with the knob cannot re-break it. Five ticks land 58 px
  apart on the shipped bar in landscape and portrait alike (also asserted).
  Child mode untouched — one forgiving 96 px brush, no slider — and the adult
  boldest brush now deliberately EQUALS it, which the smoke pins down.

### BL-15: Selection feedback the finger doesn't hide — `done`
Logged 2026-08-06 from playtest. Two related problems with picking colors
(and brush sizes): while the player's finger is down it **covers the very
item being picked** (worst during BL-2 slide-to-select), and after release
the **current selection is hard to spot** (the swatch ring and crayon lift
are too subtle at arm's length / kid attention). Three parts:
1. **Pick preview above the finger.** While a press/drag is claimed by a
   palette, show a floating preview bubble offset **above** the touch point —
   the keyboard-key-preview pattern — showing the candidate color (and on the
   size slider, the candidate diameter as a filled dot). It follows the finger
   during a slide, updates as the candidate changes, and fades out on release.
   Drawn from primitives like the rest of the shell; never under the finger;
   purely visual (no hit-testing, `MOUSE_FILTER_IGNORE`).
2. **Always-visible current selection.** An at-a-glance "now painting with"
   indicator that no finger ever covers — a swatch of the active color (with
   the active brush diameter as a dot inside it) docked at the palette's edge
   or in the toolbar. Updates on `color_picked`/`brush_size_picked`. This is
   the definitive answer to "which one is selected", independent of per-item
   styling.
3. **Stronger per-item selected states.** Strengthen what exists rather than
   redesign: the selected swatch's ring gets thicker/higher-contrast (and the
   swatch itself can scale up a touch); the selected crayon's lift/glow gets
   more pronounced. Both must read clearly at 2–3 ft on a phone.
- Both palettes share the contract (`color_picked`/`brush_size_picked`,
  `PaletteSlideInput` for the drag) — put the preview bubble in one shared
  component, not per-palette copies.
- Affected: `scripts/components/palette_slide_input.gd` (candidate-change
  hook), new shared preview component, `palette_child.gd`, `palette_adult.gd`,
  `swatch_button.gd`, `crayon_button.gd`, `brush_size_slider.gd`,
  `scenes/screens/coloring_page.tscn` (indicator placement), palette smoke.
- Done, all three parts.
  1. **`PickPreview`** (`scripts/components/pick_preview.gd`, new) — one shared
     component, drawn from primitives: a round paper bubble with a tail, parked
     so its tip is 16 px above the touch point and the whole bubble is ABOVE it
     (the smoke measures that, not just "it appeared"). `show_color()` fills it
     with the candidate colour; `show_brush()` fills it with a dot of the
     candidate diameter inside a faint ring standing for the palette's biggest
     brush, in the colour actually loaded — so the size preview answers "how big
     a mark will this make", not "here is an abstract circle". It is
     `MOUSE_FILTER_IGNORE` with no `_input` at all, so it can never be
     hit-tested and can never disturb BL-2's drag claim over the swatch
     scroller, and it draws at `z_index = 200` with `z_as_relative = false` —
     absolute, because the palette and the toolbar are different branches of the
     coloring screen and the bubble has to beat both. It fades out over 0.18 s.
     Each palette owns exactly one, parented to its own ROOT (a plain `Control`,
     so nothing lays it out) — it is not injected, so the palettes stay
     self-contained and the smoke can drive them standalone.
  2. **Candidate reporting lives in `PaletteSlideInput`**, not in either palette:
     `set_candidate_hook(on_candidate, on_release)` fires on gesture start and on
     EVERY drag event (not only when the pick changes, because the bubble has to
     follow the finger regardless), and `cancel()` now fires the release hook
     exactly once per gesture, so a rebuild or a scrim fades the bubble like a
     lifted finger does. The size slider is outside that helper's hit area by
     design, so `BrushSizeSlider` gained its own `preview_changed` /
     `preview_ended` — emitted from `pick_at_local_x()`, before its
     already-picked early-out — feeding the SAME bubble.
  3. **`ActiveBrushIndicator`** (`scripts/components/active_brush_indicator.gd`,
     new) — the "now painting with" chip: the active colour with the active
     diameter as a dot inside it, scaled against the palette's biggest brush so
     it means the same thing in both modes. **Docked in the toolbar**, not at the
     palette's edge: the toolbar is at the opposite end of the screen from the
     hand in BOTH orientations, whereas in a portrait window the palette fills
     the bottom and its edges are exactly where a thumb rests. It also needs no
     portrait special case — it is 72x60 next to the padlock and still fits the
     720 px toolbar that already drops the page title. `ColoringPage` feeds it
     from the same two palette signals that drive `PageView.brush_color` /
     `brush_size`, so it is authoritative rather than a second opinion.
  4. **Per-item states strengthened, not redesigned.** A selected `SwatchButton`
     now GROWS (idle inset 11 px → selected 6 px, a ~1.2x pop out of the grid)
     inside a 5 px contrast ring plus a 2 px dark keyline — and every ring is
     kept inside the swatch's own box, so the grid's `ScrollContainer` cannot
     clip the selection off an edge swatch. A selected `CrayonButton` lifts 26 px
     instead of 16 (over a third of its own width), is the widest crayon in the
     row as well as the tallest, gained two halo layers and more opacity, and
     wears a bright rim under its dark outline — the dark outline alone vanished
     against a dark crayon at arm's length. The halo spreads mostly SIDEWAYS
     (`GLOW_VERTICAL_RATIO`) because the row's scroller clips vertically and a
     hard-cut glow looks worse than a narrow one.
- Gotcha worth keeping: `get_anchor()` is a native `Control` method
  (`get_anchor(Side) -> float`). Naming a getter that on a `Control` subclass is
  a hard parse error that takes every depending script down with it —
  `get_anchor_position()` now.
- Still open: nothing from this entry. The bubble is colour/size only; if a
  future palette grows a third kind of pick it needs a third `show_*`.

### BL-16: Pick feedback, round 2 — `done`
Logged 2026-08-06 from playtest of the BL-15 build. Four adjustments:
1. **Remove the "now painting with" chip** (`ActiveBrushIndicator`) from the
   toolbar entirely — delete the component and its wiring/smoke checks. The
   pick-preview bubble and stronger item states (below) carry the job alone.
2. **The pick bubble must vanish when the player stops pressing.** It already
   fades on release in the known paths — verify EVERY path on the web build
   (touch, mouse, slide off the palette, slider release, palette rebuild) and
   fix any that leaves the bubble stranded on screen.
3. **The pick bubble twice as large, floated higher** above the press point —
   double its drawn size and increase the vertical offset so neither a finger
   nor the hand shadows it.
4. **Selected states, louder again.** The BL-15 pass was not enough on-device:
   the selected crayon and the selected swatch must be unmistakable at a
   glance — more scale/lift/contrast (and motion on selection is fine, e.g. a
   small settle bounce), while staying primitive-drawn and inside the
   palette's clipping constraints (the crayon row clips vertically, the
   swatch grid scrolls).
- Affected: `scripts/components/active_brush_indicator.gd` (delete),
  `scenes/screens/coloring_page.tscn` + `coloring_page.gd` (chip wiring),
  `scripts/components/pick_preview.gd`, `palette_slide_input.gd`,
  `swatch_button.gd`, `crayon_button.gd`, `brush_size_slider.gd`,
  dev smokes, `.claude/skills/coloring-mechanics/SKILL.md` (chip + contract
  facts, after implementation).
- Done, all four.
  1. **The chip is gone.** `active_brush_indicator.gd` deleted, with its toolbar
     node, `ColoringPage.get_brush_indicator()`, the two lines that fed it from
     `color_picked`/`brush_size_picked`, and its checks in the palette and flow
     smokes. `_on_color_picked` is one line again: the palette drives the brush,
     full stop. The flow smoke now asserts the node is **absent**, so the chip
     cannot come back by accident.
  2. **Dismiss audit.** `PaletteSlideInput` only fades the bubble for gestures it
     CLAIMED, and the bubble is raised by the button under the finger, not by the
     helper — so every press the helper refused (outside its hit area, another
     control hovered, a scrim opening mid-gesture) could raise a bubble whose
     release nobody was listening for. Three fixes, cheapest first: both palettes
     now treat **any** pointer release reaching their `_input` as "nothing is being
     picked" (`PaletteSlideInput.is_release_event()` — one definition of "release"
     for both, an instance method because a `static` on a `class_name` has bitten
     this project before); `PaletteAdult` additionally ends the **slider's**
     preview from there, because `BrushSizeSlider` hears its own release through
     `_gui_input`, which never arrives if the finger slid off the bar first — that
     also left `_dragging` stuck true, so the bar kept picking on later motion; and
     `PickPreview` hides itself on `NOTIFICATION_APPLICATION_FOCUS_OUT` /
     `WM_WINDOW_FOCUS_OUT` / `EXIT_TREE`, which is the web case where the release
     is never delivered at all (tab switch, finger off the canvas). The palette
     rebuild path was already correct (`_clear()` → `hide_now()`, plus the whole
     palette is freed on a mode change) and is now covered by a check.
  3. **Twice the size, three times the offset.** `BUBBLE_RADIUS` 46 → 92,
     `TAIL_HEIGHT` 18 → 36, `TAIL_HALF_WIDTH` 13 → 26, and every stroke weight
     inside it doubled (new `CONTENT_INSET`/`RIM_WIDTH`/`CHIP_EDGE_WIDTH`/
     `TAIL_EDGE` constants instead of the magic numbers). `FINGER_GAP` 16 → 48:
     the fingertip was never the problem, the **hand** behind it was, and 16 px put
     the tail under the player's own knuckles.
  4. **Louder items, with a settle bounce.** Crayon: `LIFT_PX` 26 → 34 (half its
     own width), selected width 0.84 → 0.94 against an idle 0.70 → 0.64 (a
     selected crayon is now 1.47x the width of its neighbours), 8 halo layers at
     0.20, a heavier bright rim. Swatch: insets 11/9/6 → 13/11/8, so the selected
     patch is 1.33x an idle one, inside a 6 px ring. Both bounce on selection —
     and the two bounces are deliberately **different mechanisms**, because the
     two clipping constraints are different. The crayon springs its drawn LIFT
     (`SELECT_BOUNCE_SCALE`) inside the new `LIFT_HEADROOM` the box reserves, so
     the row's vertical clip can never slice the peak; the swatch springs its own
     `scale` transform, which does briefly draw over its neighbours, and that is
     acceptable *because it is transient* — the rule the grid's scroller enforces
     is about the state a swatch RESTS in, and every resting pixel is still inside
     its box.
- Gotcha worth keeping: `LIFT_HEADROOM`, not `LIFT_PX`, is what a lifted crayon's
  box has to reserve. Animating a lift without headroom for the overshoot gets the
  peak of the motion clipped — the one frame the animation exists for.
- Still open: nothing. The bubble is clamped to the screen top, so on a very short
  window a bubble raised near the top edge can still come down over the finger;
  that is the correct trade (visible beats correctly-placed and off-screen).

### BL-17: Undo / redo — `done`
Logged 2026-08-06 from playtest. Undo and redo buttons **at the top of the
page** (the coloring toolbar), undoing one stroke at a time.
- **Model: replay, not snapshots.** A full paint-layer snapshot is ~14 MB at
  page resolution — a stack of them is not mobile-viable. Instead record each
  committed stroke's recipe (locked region id, color, diameter, hardness, the
  stamped page-space points) — a few KB per stroke. Undo = clear the paint
  SubViewport, re-composite the page's **baseline** (the restored save PNG,
  when one was loaded — the same one-frame `PaintRestoreQuad` premult path M5
  built), then replay every remaining stroke's stamps in order. Redo =
  replay the popped stroke. Replay must reproduce the original stamps
  exactly (same points, same shader path), so undo→redo is pixel-stable.
- **History is per page visit**: it starts empty when a page opens (the
  restored PNG is baseline, not an undoable stroke), caps at a bounded depth
  (suggest 50 strokes; drop the oldest — "undo past the cap" is not a kid
  expectation), and clears on navigation/Start over. Never persisted.
- **Coverage after undo/redo**: re-settle the tracker from a fresh readback
  with `CoverageTracker.update_all()` (the mode-switch re-settle path), then
  save-mark dirty. Completion status stays **sticky** per BL-10 — undoing
  below the threshold never downgrades `complete` (only Start over does,
  BL-7) and a redo that re-crosses the threshold must not re-celebrate
  (once-per-tracker already guarantees it).
- **Interlocks**: buttons disabled when their stack is empty; both disabled
  while the page is **locked** (padlock, BL-10 — same rationale as Start
  over); a new stroke clears the redo stack (standard); undo/redo refused
  mid-stroke and while a flip/navigation is in transit; autosave's
  "never mid-stroke" rule extends to "never mid-replay".
- Buttons drawn from primitives like the rest of the toolbar (no icon
  assets); ≥48 px touch targets.
- Affected: `scripts/components/page_view.gd` (stroke recipe capture +
  replay/rebuild API — additive; the stroke lifecycle itself is frozen),
  `scripts/screens/coloring_page.gd` + `scenes/screens/coloring_page.tscn`
  (buttons, stacks, coverage re-settle), dev smokes,
  `.claude/skills/coloring-mechanics/SKILL.md` (after implementation).
- Done, on the entry's model exactly. `PageView` records what `PaintCanvas`
  already batched: `take_last_stroke_recipe()` hands the finished stroke's
  stamps up as a dict, `rebuild_paint(baseline, recipes)` clears the
  SubViewport, re-composites the baseline image (the M5 premult path) and
  re-stamps every recipe in order, and `stamp_recipe()` replays exactly one.
  `ColoringPage` owns the two stacks. **Undo is the rebuild; redo is a single
  `stamp_recipe()`** of the popped entry — same points, same shader path,
  which is what makes undo→redo pixel-stable (the flow smoke compares the
  actual pixel). `UNDO_DEPTH` (50) is enforced with `_undo_floor` rather than
  dropping recipes: a rebuild needs the WHOLE history to stay pixel-exact, so
  old strokes are kept and merely made un-undoable. The restored save PNG is
  `_baseline_paint` — baseline, never an undoable stroke.
  `_can_edit_history()` is the one gate (locked / restoring / mid-stroke /
  transitioning all refuse; `is_replaying()` itself counts as a transition,
  so navigation, saves and the second history tap all wait it out); a new
  stroke clears redo; history dies with the visit (navigation, Start over) and
  is never persisted. Coverage re-settles via `update_all()` from a fresh
  readback under a bumped page generation (the BL-7 mechanism) so an
  in-flight readback of pre-undo paint cannot pollute the tracker — and
  completion stays sticky both ways: undo never downgrades, redo never
  re-celebrates. The toolbar arrows are `HistoryButton`
  (`scripts/components/history_button.gd`, primitive-drawn, 60×60).
- Gotcha (cost the whole flow smoke a silent no-parse hang): `undo()`/`redo()`
  are coroutines, and GDScript makes READING a coroutine's value without
  `await` a parse error. Refusals return `false` before the first await, so
  `await screen.undo()` is synchronous for refusal tests; asserting mid-flight
  state needs the Callable-into-cells launch (see the flow smoke and the
  coloring-mechanics skill).

### BL-19: DLC pack download stalls on the web build — `done`
Found 2026-08-06 during the live end-to-end on http://192.168.0.164:91/ (the
first run with the API reachable from a browser). Tapping Get → "Yes,
download" fetches `/packs/{slug}/manifest` (200, and the free entitlement
auto-grants) but the `/download` request is never issued — the row sits at
"Downloading… — of 928 KB" forever, no console error, nothing in nginx.
The identical install path is green natively (`backend_smoke` check e), so it
is web-export-specific. Prime suspect: the deliberate `max_redirects = 0`
"read the 302's `Location` header ourselves" step (WP10 — done so the bearer
token is never forwarded to the signed URL). Browser `fetch()` does not expose
redirect responses to the caller: on web, Godot's `HTTPRequest` gets an opaque
or auto-followed response, so `location` is empty and the installer waits on a
URL it never received. Likely fix: on the web platform let the request follow
the redirect (same-origin signed URL carries no auth header anyway, and the
token is stripped by the server's 302 hop — verify), or have the API return
the signed URL in a JSON body for web clients. Note the paint-layer pull in
`sync_queue.gd` uses the same `max_redirects = 0` pattern and almost
certainly stalls the same way on web — fix both.
Also worth folding in from the same session: `sync_smoke` needs its scratch
password to satisfy production `Password::defaults()` (mixed case) before it
can ever run against the live server, and its two pre-existing check-(k)
failures (`BUSY` vs `NETWORK_UNREACHABLE`) plus the Vulkan-driver
`HTTPRequest` CONNECTION_ERROR quirk are documented in the 2026-08-06 session
notes.
- Affected: `scripts/backend/pack_installer.gd`, `scripts/backend/sync_queue.gd`
  (paint pull), possibly `api_client.gd` (a follow-redirects-on-web branch),
  `scripts/dev/sync_smoke.gd`
- Blocks: installing DLC from the web build (native installs work).
- Done. **The diagnosis was right, and it is not a setting we could have got
  wrong — a browser cannot read a redirect at all.** Godot's web HTTP client is
  one line of JavaScript, and it is in every export: `GodotFetch.create` calls
  `fetch(url, {method, headers, body})` with **no `redirect` option**, so the
  browser uses the default `"follow"`, chases the 302 itself, and hands the
  engine the FINAL response. `max_redirects = 0` has nothing left to act on.
  Measured in Chrome against a local 302 rather than argued from the spec
  (`php -S` on two ports, one page, three fetches):
  ```
  fetch(302) default        → status 200, redirected true, url = the target,
                              headers.get("location") === null — and so is every
                              other header the 302 itself carried
  fetch(302) redirect:manual → an OPAQUEREDIRECT: status 0, no headers at all
                              (and Godot never asks for it anyway)
  ```
  So `ApiClient.KEY_LOCATION` is permanently `""` on web, the installer's
  "read the Location ourselves" step can never produce a URL there, and what
  the two-step actually did in a browser was fetch the whole 950 KB archive
  into RAM as if it were JSON before fetching it again.
- **The bearer token is safe on the hop, by the browser's own rule** — the
  thing the manual 302 handling was protecting, verified rather than assumed in
  the same run: on a **same-origin** redirect fetch forwards `Authorization`
  (the second hop saw `Bearer PROBE-TOKEN`), and on a **cross-origin** redirect
  it **strips** it (the second hop saw nothing). A web build is same-origin by
  construction — `BackendConfig.for_web_origin()` puts the API on the page's own
  origin and `redirect()->away()` signs a route on it — so the token reaches an
  origin it is already sent to on every call, and nobody new. If pack delivery
  ever moves to a CDN on another origin, the browser removes the header without
  being asked. Server-side the signed route is `VerifySignedDownload` only, with
  no Sanctum guard, so an extra `Authorization` header is ignored.
- **The fix is one predicate and two branches, client-only.**
  `ApiClient.can_read_redirects()` (`not OS.has_feature("web")`) carries the
  whole platform fact and the measurements above in its doc comment.
  `PackInstaller._install` asks it: native keeps the existing two-step
  (`follow_redirects: false` → read `Location` → download the signed URL with
  `auth: false`) **byte for byte**; web skips straight to
  `_api.download("/packs/<slug>/download", …)`, one authorised request streamed
  to disk with the browser doing the redirect. `SyncQueue._pull_page_paint` does
  the same for the paint blob — where the old code did not hang but returned
  `false` on an empty URL, i.e. a web device would have *silently never pulled a
  picture*, which is the worse bug of the two because nothing looks wrong.
  No server change: `GET /packs` and the 302 are exactly as they were.
- Also folded in from the same session, as the entry asked:
  - **Both smokes' scratch passwords are now mixed-case with a digit**
    (`Wp10-Smoke-Passphrase-7` / `Wp11-…`), so registration satisfies a
    production `Password::defaults()` and neither harness is dev-box-only.
  - **`sync_smoke`'s two check-(k) failures were the harness racing itself**, not
    `BUSY` vs `NETWORK_UNREACHABLE` being wrong: the save point above the check
    schedules a debounced drain, a drain that fails offline reschedules itself
    with backoff, and the manual `sync_now()` landed on top of one and was
    correctly answered `BUSY` — which then also kept the status line off
    "Offline". It waits the other drain out and asks again. **87/87.**
  - **The Vulkan `CONNECTION_ERROR` quirk is written into the smoke's run
    instructions** (`--rendering-driver opengl3`): under Vulkan every
    `HTTPRequest` `sync_smoke` makes comes back `RESULT_CONNECTION_ERROR` (4)
    before a byte leaves and the server never sees it; the same requests succeed
    headless and under GL. A windowed Vulkan run fails at "register a scratch
    account" and proves nothing, so the flag is not optional.
- Not verified here, by arrangement: the live download in a real browser
  against the port-91 site. The mechanism is proved and the native path is
  unchanged (`backend_smoke` check (e) still downloads and verifies the real
  950 KB archive); the end-to-end tap belongs to the deploy that follows.

### BL-20: Remove the Child/Adult split — one crayon palette — `done`
Logged 2026-08-07. Remove the mode choice entirely: the game always uses the
crayon palette (the former child palette). Full design: DESIGN.md §1.
- Delete the mode-select screen (`scenes/screens/mode_select.*`) and the
  settings mode switch; `main.gd` goes TitleScreen → BookSelect directly.
- Delete the adult palette and everything only it used:
  `palette_adult.tscn`/`.gd`, `swatch_button.gd`, `brush_size_slider.gd`,
  `adult_palette.tres`. The brush-size slider (BL-3/BL-14) dies with it — the
  crayon palette keeps its single forgiving 96 px brush, as today.
- `GameState.mode` and the save's `"mode"` field become vestigial: nothing
  writes or branches on them, the reader keeps tolerating the key, and
  `SAVE_VERSION` does not move (additive-tolerant, the BL-10 pattern).
- Completion threshold: the single palette's **0.90** (BL-5's child value).
- Server side: progress rows and sync payloads were always keyed per book,
  never per mode — no server change. `child_profiles.default_mode` becomes
  vestigial (column stays; nothing reads it).
- Affected: `scripts/main.gd`, `scenes/screens/mode_select.*` (delete),
  `scenes/components/palette_adult.tscn` + `palette_adult.gd` +
  `swatch_button.gd` + `brush_size_slider.gd` (delete),
  `resources/palettes/adult_palette.tres` (delete), `autoload/game_state.gd`,
  `scripts/screens/coloring_page.gd` (mode plumbing), dev smokes (palette/
  flow/shell/mobile all assert the split today),
  `.claude/skills/coloring-mechanics/SKILL.md` (after implementation).
- Done. **Eleven files deleted** and nothing left behind that could grow the split
  back: `mode_select.{tscn,gd}`, `palette_adult.{tscn,gd}`, `swatch_button.gd`,
  `brush_size_slider.gd`, `adult_palette.tres`. The palette smoke now asserts each
  of those paths is *gone* (`ResourceLoader.exists` + `FileAccess.file_exists`),
  because "we removed it" is the kind of claim that quietly stops being true.
  **The crayon palette kept its names.** `PaletteChild` / `palette_child.tscn` /
  `child_palette.tres` are still called that: DESIGN.md §3.4 names them, they are
  referenced from a dozen places, and a rename would have been the largest and
  least useful diff in the entry. The class doc says out loud why.
  **`GameState` lost its mode surface entirely** — `mode`, `set_mode()`,
  `mode_changed`, `is_child_mode()`, `get_available_modes()`,
  `get_palette_for_mode()`, `PALETTE_PATHS`, `MODE_CHILD`/`MODE_ADULT`,
  `DEFAULT_MODE`. What is left is `get_active_palette()` (one cached
  `PaletteDef`) and `get_palette_scene_path()` (one scene). `PaletteDef` lost
  `mode` and `shades_per_family` + `family_count()`/`get_family()`/
  `effective_shades_per_family()`, which existed only for the swatch grid.
  `ColoringPage` lost `_on_mode_changed()` and the `palette_rebuilt` signal: with
  one palette and one threshold, nothing rebuilds mid-book.
  **The save's `"mode"` key is read but never written.** `load_save()` reads past
  it (a new `GameState.VESTIGIAL_SAVE_KEYS` names it, so the tolerance is
  declared rather than accidental) and `to_save_dict()` no longer emits it.
  `SAVE_VERSION` deliberately did **not** move — dropping a key nobody reads is
  additive-tolerant in both directions, the same argument BL-10 made for adding
  one — and the smokes prove both halves: a planted pre-BL-20 file loads, and the
  file written back is the same schema version without the key.
  **Threshold**: the single 0.90. `CoverageTracker` was not touched; it is still
  injected from the `PaletteDef` and still clamps against `MIN_REGION_THRESHOLD`.
  **Settings** lost its Mode row; it now shows *which* crayons the game paints
  with (`Crayons — Crayon Box`) and offers nothing to change about it, so the
  panel is still an honest inventory rather than a dead end.
- **The mode-split assertions were rewritten, not deleted** (the point of the
  exercise). Shell check (a) now asserts the title tap reaches the shelf DIRECTLY
  and that `main` has no `show_mode_select`/`get_mode_select_overlay` left; check
  (f) — "change mode mid-book" — became "one palette, one threshold, nothing to
  change mid-book", which opens settings over an open book and asserts there is
  no Mode row and the palette it opened with is the palette it still has; check
  (b) asserts the save has NO `"mode"` key; the DLC smoke's v1-migration check
  asserts the same. Palette check 1 asserts the deleted files are gone and that
  `PaletteDef` carries no `mode`/`shades_per_family`; check 8 asserts `GameState`
  has no mode property, method or signal, and drives the save round-trip above.
- Smokes: **palette 112 → 72** (the adult half's 40-odd checks went with the
  adult palette; the rewrites above landed in their place), **shell 147 → 142**,
  **mobile 139 → 133** (its portrait pass no longer has a mode-select screen to
  stack cards on), **flow 159 → 159** and **dlc 90 → 90** (one assertion swapped
  each). paint 47 untouched. Also fixed while in there: shell/mobile wiped their
  own screenshot directory in setup and then failed every `save_png` — the shot
  dir is re-made in `_screenshot()` now.

### BL-21: Landscape layout — crayons dock beside the canvas — `done`
Logged 2026-08-07 from playtest. Portrait ("vertical") looks good — keep it.
In landscape the bottom crayon row eats the already-short screen height:
dock the crayons on the **side** of the canvas as a vertical column instead.
Same palette scene, orientation-keyed layout (aspect ratio, not width —
DESIGN.md §3.5). Everything the row carries must work in both orientations:
slide-to-select (BL-2), the pick-preview bubble (BL-15/16 — offset away from
the hand still, which is sideways now), the crayon lift/halo (the lift must
point INTO the canvas, with headroom reserved per BL-16's clipping gotcha),
and the swap/set controls arriving with BL-22/BL-23.
- Affected: `scenes/screens/coloring_page.tscn`,
  `scripts/screens/coloring_page.gd`, `scenes/components/palette_child.tscn`,
  `scripts/components/palette_child.gd`, `crayon_button.gd` (lift direction),
  `palette_slide_input.gd` (hit-testing), `pick_preview.gd`, dev smokes.
- Done. **One `BoxContainer`, pointed two ways.** `coloring_page.tscn`'s `Ui`
  VBox gained a `Body` between the toolbar and the page; `PageView` and the
  palette are its two children, in that order, always. Portrait points `Body`
  down (crayons under the canvas — pixel-identical to before), landscape points
  it across (crayons to the right of it). A plain `BoxContainer`, not an
  H/VBoxContainer, because those two refuse `set_vertical()` — the same trap M6
  hit with `ModeSelect`. `ColoringPage.is_landscape()` is `size.x > size.y`:
  **aspect, never width** (DESIGN.md §3.5 — a portrait window's logical canvas
  never gets narrow, so a width threshold is keyed off nothing).
  `PaletteChild.set_layout()` does the rest with four moves and no second scene:
  the strip's `custom_minimum_size` and size flags swap axes (212 px across its
  short one either way), `Body`/`CrayonRow` flip direction, the `ScrollContainer`
  swaps which axis scrolls, and the crayons change orientation.
- **The crayon rotates rather than forking.** `CrayonButton._draw()` now sets up a
  CANONICAL space — tip up, lift rising — and `ORIENT_LEFT` rotates it a quarter
  turn anticlockwise (`draw_set_transform(Vector2(0, size.y), -PI/2)`) before a
  single pixel is drawn, so canonical `(x, y)` lands at screen `(y, height - x)`.
  Not one drawing routine was duplicated, and — the reason it is worth doing this
  way — everything expressed in canonical space follows for free: the lift points
  canonical UP, which is screen LEFT, which is **into the canvas** when the column
  is docked on the right; `LIFT_HEADROOM` is still reserved at the canonical top,
  so BL-16's bounce overshoot still has somewhere to go; and the halo still
  flattens along the axis the scroller clips, because that axis is canonical in
  both orientations. `box_for()` and `lift_direction()` are the public handles the
  smoke measures instead of trusting the constants.
- **The pick bubble parks sideways.** `PickPreview` had "above the finger" baked
  into its size, its tail and its clamp; all three are now one direction vector
  (`get_tail_direction()` — DOWN for `PLACE_ABOVE`, RIGHT for `PLACE_LEFT`). The
  body circle always sits in the box's top-left and the tail is what makes the box
  longer on one axis, so `_size_for()`, `_reposition()` and `_draw()` are each a
  single expression in that vector. The palette sets the placement when its layout
  flips: the hand comes in from the side the crayons are docked on, so the bubble
  goes the other way. `_reposition()` also clamps BOTH axes now — a clamp on the
  tail's axis can only push the bubble further from the finger, never onto it.
  Slide-to-select needed **nothing**: `PaletteSlideInput` hit-tests real control
  rects in viewport space, which does not care which way a strip runs.
- **Gotcha:** the docked column is 212 px wide and a crayon is 176 px long, so
  ten crayons no longer fit on a 738 px-tall canvas — the strip scrolls, which is
  correct and future-proof (BL-23's sets can be any length) but means the last
  crayon is a flick away in landscape where it was on screen in portrait.
- Smokes: **palette 72 → 92** (new check 5b flips the layout and back: the strip's
  thickness moves axes, the scroll swaps direction, every crayon lies on its side
  and stacks, the touch target holds, the lift points LEFT and still springs
  inside its headroom, the bubble parks entirely to the left of the finger at the
  same `FINGER_GAP`, and flipping back restores the row exactly),
  **mobile 133 → 141** (portrait is asserted as the UNCHANGED case — strip below
  the canvas — then the window goes back to landscape and the same screen, same
  palette instance, docks as a column beside the page, costs the canvas only the
  strip's width, keeps its touch targets and lifts left; `coloring_landscape_dock.png`
  is the new screenshot).

### BL-22: Crayon intensity — swap the row from colors to light→dark — `done`
Logged 2026-08-07. Full design: DESIGN.md §1. A swap control on the crayon
row toggles between **color crayons** and **intensity crayons**: shades of
the currently selected color from a pale tint to a deep shade (~7 steps,
**derived** from the base color — computed, never authored per color).
Picking an intensity resolves the paint color (base × step) through the
existing `color_picked` chain — the paint path, shader and stroke lifecycle
do not change. Picking a new base color resets intensity to the full/middle
step; in intensity view the selected crayon shows which step is active, and
the swap control makes the current view obvious (kid-readable, drawn from
primitives like the rest of the shell).
- Affected: `scripts/components/palette_child.gd`, `palette_child.tscn`,
  `crayon_button.gd` (render a shade), a small intensity-ladder helper (in
  `PaletteDef` or a component), `pick_preview.gd` (bubble shows the resolved
  shade), palette smoke, `.claude/skills/coloring-mechanics/SKILL.md`.
- Done. **The ladder is arithmetic, not data.** `PaletteDef.shade_of(base, step)`
  is a pure function: `INTENSITY_STEPS` = 7, `INTENSITY_BASE_STEP` = 3 (the
  crayon's own colour), rungs below it lightened linearly to `MAX_TINT` 0.72 and
  above it darkened linearly to `MAX_SHADE` 0.60, alpha untouched.
  `shades_of(base)` returns the whole ladder. That is the entire feature's data
  model, and it is why BL-23's sets get intensity for free — a per-colour table
  would have been nine numbers to get wrong for every crayon of every set, and
  every new set would have shipped without one.
- **The strip grew a second face, not a second component.** `PaletteChild` has a
  `_view` (`VIEW_COLORS` / `VIEW_SHADES`) and `_rebuild_strip()` builds the crayon
  buttons for whichever is up — the same `CrayonButton`s, carrying either the box's
  colours or the ladder of the colour in hand. One pick callback (`_pick_at`)
  dispatches on the view, so `PaletteSlideInput` never learns any of this exists
  and slide-to-select works identically on both faces.
- **Nothing downstream of the palette changed**, which was the constraint. The
  active pick is always "crayon C at rung R"; `get_selected_color()` resolves it
  in one place and `color_picked` carries the resolved colour exactly as it always
  did. `ColoringPage`, `PageView`, `brush.gdshader`, the stroke lifecycle and the
  coverage path were not touched. The pick bubble shows the resolved shade
  (`_candidate_color()`), because the bubble's job is "what will this paint".
- **Picking a crayon resets the rung** to its own colour (the design's
  full/middle step), so a child who wandered to rung 6 once is not stuck there for
  every colour afterwards. Swapping the VIEW, in either direction, is deliberately
  **not** a pick — it emits nothing and the brush keeps whatever shade is on it.
- **`IntensityButton`** (`scripts/components/intensity_button.gd`, new,
  primitive-drawn, 88 px) answers two questions in one tile: it draws the whole
  ladder of the current crayon with the ACTIVE rung wider inside a bright rim and
  a dark keyline — the same grammar a selected `CrayonButton` uses, and visible
  when no finger is anywhere near the strip (BL-15's lesson) — and it changes
  state to say what pressing does: closed tile with a chevron pointing in while
  the colours are up, open tile with a gold border and the chevron pointing back
  out while the ladder is. It lives in a new `Controls` box on the strip, OUTSIDE
  the crayon scroller, so a slide can never land on it.
- Smokes: **palette 92 → 117**. The ladder is asserted as derived (rung 3 of every
  crayon IS that crayon; all ten ladders run pale to deep without a break;
  `PaletteDef` authors no shade table), and the swap is driven the way a finger
  would: the strip becomes exactly `shades_of(base)`, a shade press emits
  `color_picked` ONCE carrying the RESOLVED colour, the crayon in hand is still
  the crayon in hand, the bubble previews the resolved shade, swapping back keeps
  the shade on the brush, and picking a new crayon comes back to rung 3.

### BL-23: Fun crayon sets (Mario Paint-inspired) — `done`
Logged 2026-08-07. Full design: DESIGN.md §1. Additional authored crayon
**sets** beyond the default box — fun and unique, in the Mario Paint spirit —
cycled with a crayon-box control on the row: e.g. Pastel, Neon, Earth, Candy,
Spooky. Each set is authored data (colors only; brush size and completion
threshold stay with the base palette), and swapping sets swaps the row's
colors and nothing else. Intensity (BL-22) works on every set for free since
its steps are derived. Optional stretch, not required to close this entry:
one special rainbow crayon that cycles hue along the stroke (per-dab color —
cheap with the existing stamped-quad brush).
- Affected: `resources/palettes/` (new set resources),
  `scripts/resources/palette_def.gd` (or a lighter `CrayonSetDef`),
  `palette_child.gd`/`.tscn` (set-cycling control), palette smoke,
  `.claude/skills/coloring-mechanics/SKILL.md`.
- Done. **`CrayonSetDef`** (`scripts/resources/crayon_set_def.gd`, new) is the
  lighter resource the entry offered: `display_name`, `sort_order`, `colors`, and
  that is the whole class. It cannot carry a brush size, a hardness or a
  threshold — the palette smoke asserts those properties are ABSENT, because a
  crayon box that could change how the game plays is a difficulty mode wearing a
  hat, and BL-20 had just finished deleting those.
  **Sets are DISCOVERED, not listed**, exactly like books: `CrayonSetDef.discover()`
  scans `res://resources/palettes/sets/*.tres` and sorts by `sort_order` then name,
  so shipping a box is dropping a file and the cycle order does not depend on
  filenames (or on hand-writing a typed `Array[CrayonSetDef]` into a `.tres`,
  which was the alternative and is exactly the kind of serialisation that breaks
  quietly). It handles `.remap` for exported builds, like `BookDef` does.
  **Five shipped**: Pastel, Neon, Earth, Candy, Spooky — ten crayons each.
- **One index covers both kinds of box.** `PaletteDef.get_crayon_set_colors(i)`:
  0 is the palette's own `colors` (the default box, which stays authored on the
  palette because the title screen, the boot splash and the confetti all read it),
  1..n are the discovered sets. `crayon_set_count()` / `wrap_crayon_set()` /
  `get_crayon_set_name()` complete it, and the discovery is cached
  (`reload_crayon_sets()` for tests). Callers never have to know which is which.
  `PaletteChild._active_colors()` is the one line that changed to make the strip
  set-aware; **intensity then worked on every set with no further code at all**,
  which is the payoff for BL-22 deriving the ladder.
- **A new box is a fresh start**: first crayon, own colour, colours face. Leaving
  a child on rung 6 of a colour that no longer exists was the alternative.
  `set_crayon_set()` emits one `color_picked` with the new crayon; the brush size
  is untouched and the smoke asserts it, because that is the whole "colours only"
  claim in one number.
- **`CrayonBoxButton`** (`scripts/components/crayon_box_button.gd`, new,
  primitive-drawn, 88 px, next to the intensity swap) draws a carton with the
  CURRENT set's first five crayons standing in it, a pip per box with the current
  one filled, and a right chevron. It reports the position rather than previewing
  the destination — the opposite convention from `IntensityButton` next to it, and
  deliberately so: the ladder is a mode you go into and come back out of, the
  boxes are a carousel with no home. No text: the set's name is the obvious label
  and is exactly what a four-year-old cannot use.
- **Gotcha:** the two 88 px tool tiles share the strip's SHORT axis with its
  margins (212 − 24 = 188 px in a row, 212 − 28 = 184 px in a column), so they fit
  with 2 px to spare. Growing either tile, or adding a third, overflows the strip
  in silence — the palette smoke now measures every tool tile against the strip's
  own rect in all three layouts rather than trusting the arithmetic.
- **Not done: the optional rainbow crayon.** It was explicitly a stretch, and the
  cheap version of it (per-dab colour along a stroke) is the one thing in this
  round that would have had to reach into the frozen stroke lifecycle. Left open.
- Smokes: **palette 117 → 146** (new check 5d: the five sets are discovered in
  authored order and validate, no two crayons in a box are closer than 0.10 apart
  — a looser floor than the default box's 0.25, because a Pastel box whose crayons
  were a quarter of the colour cube apart would not be a pastel box — a set
  carries no brush/threshold/mode property, box 0 IS the palette's own crayons,
  pressing the control swaps the strip and puts its first crayon in hand without
  moving the brush, the ladder works on a set crayon with nothing authored for it,
  and cycling past the last box wraps home; plus the tool-tile fit check in all
  three layouts).

### BL-24: Web authoring — book & page CRUD + one-button publish — `done`
Logged 2026-08-07. Full design: DLC_SERVER.md §10.3. The admin website
(`server/`, Inertia) becomes a full authoring surface. Three parts:
1. **Books CRUD**: create and remove (empty) coloring books in the browser.
   A web-authored book gets its own one-book pack (slug = book slug) so packs
   stay the delivery/entitlement unit and the game changes not at all.
2. **Pages CRUD**: per book — add, remove, reorder, retitle pages; upload or
   replace the **detail (display) image** and the **optional masking image**
   per page (BL-9/BL-12 semantics). Each upload queues a server-side mapping
   job (headless Godot running `tools/generate_region_map.gd` — the same
   pipeline, never a PHP port), whose artifacts + §10.1 validation verdict +
   region-overlay preview land on the page editor.
3. **Publish**: one button per book — refuses while any page is unmapped or
   failing validation, otherwise builds the §7.2 pack directory and publishes
   an immutable new version through `PublishPackDirectory` +
   `PublishPackVersion` (the single existing code path). The game picks the
   version bump up through the existing entitlement/update check.
- Affected: `server/` (books/pages authoring models + routes/admin.php +
  `routes/api/admin.php`, mapping-job queue, `config/coloringbook.php`
  `godot_binary` knob, Inertia pages, Pest + Dusk coverage),
  `docs/DLC_SERVER.md` §10.3/§11 (done alongside this entry).
- Deploy note: puts a pinned headless Godot binary on the mini-pc; treat an
  engine upgrade there as a content-pipeline change (re-map a fixture page
  and diff artifacts before trusting it).
- Done, all three parts. Server-side only; `godot/` untouched. Full as-built
  notes in `server/CLAUDE.md` § "WP14 — web authoring".
  - **The authoring data model is a second pair of tables**, and that was the
    one real design decision. `books`/`pages` are a *projection of the newest
    published release* — `PublishPackDirectory` drops and rebuilds them on every
    publish, deliberately — so they can hold no draft state at all: a page
    uploaded but not yet mapped, a title changed since the last release, a
    per-page tuning override would each be deleted by the next publish. So
    `authored_books` (ulid, `book_uid` unique, `pack_id`, title, blurb) and
    `authored_pages` (uploads: `display_asset_id` + optional `mask_asset_id`;
    derived and nullable: `idmap`/`regions`/`mask_artifact` asset ids,
    `image_w`/`image_h`/`region_count`; plus `mapping_status`, `mapping_error`,
    `mapping_log`, `validation_errors`, `validation_warnings`, `tuning`,
    `UNIQUE(book, page_index)`). The workspace is draft state; the catalog is
    what players have; publish is the only thing that crosses.
  1. **Books CRUD.** One book ↔ one pack, `packs.slug = book_uid`, created
     together so the slug — a pack's permanent address in every URL the game
     builds — is reserved the moment the uid is. `is_free` chosen at creation.
     The uid is checked three ways (unique in `authored_books`, in `books`, and
     as a `packs.slug`) and can never be edited: it is what every `book_progress`
     and paint row on every device keys off. Deleting a never-published book
     removes it outright — pack, versions, catalog rows, entitlements and the
     `packs/<slug>/` directory — because leaving a dead slug behind reserves a
     uid for a mistake forever; deleting a published one **retires** the pack and
     removes only the workspace, since `scopeDownloadable()` already includes
     `retired` so delisting never takes a book off a child's shelf (§7.3).
     Content-addressed assets are never deleted either way: they are shared by
     digest and a published release may be standing on the same bytes.
  2. **Pages CRUD + server-side mapping.** Add / remove / reorder / retitle,
     upload or replace the detail image and the optional mask, either as
     multipart or as ULIDs of assets already uploaded to `POST /admin/assets`.
     BL-9/BL-12 hold exactly: mask present → the mask is the mapping source and
     `mask_artifact_asset_id` (the pipeline's display-resolution resample) ships
     as `page_NN_mask.png`; mask absent → the display image maps itself and no
     mask file appears in the pack. Each detail/mask/tuning change **clears the
     derived columns and re-queues** `App\Jobs\MapAuthoredPage` — leaving
     yesterday's ID map beside today's art is the exact failure
     `PackValidation`'s bijection check exists to catch, and it would have been
     the server that created it. The job stages a scratch tree (the mask at
     `source/mask.png`, deliberately *not* at `page_01_mask.png`, which is where
     the pipeline writes its own resample), shells out through
     `App\Services\Mapping\MappingRunner`, stores the artifacts as
     content-addressed assets and runs the existing `PackValidation`, storing the
     verdict on the row. Mapping and validating are separate verdicts: a page can
     map perfectly and still be unpublishable because one region swallowed the
     drawing — and the editor says "that is a gap in the line art, not a region",
     because only the artist can fix it. Reordering is a two-phase shuffle
     (unique `(book, page_index)`, and SQLite checks unique indexes per
     statement); deleting compacts, because a hole at index 2 would publish a
     manifest the client reads as a book with a missing page.
     Nothing in the job throws on a bad page — a failed run is a state on the
     row, since the queue retrying a gap in the line art three times only loses
     the message.
  3. **Publish.** One button. Refuses with the *whole* list of reasons while any
     page is unmapped or failing §10.1; otherwise writes a §7.2 directory from
     the book's current pages and hands it to `SubmitPackVersion` +
     `PublishPackVersion`. **No second publisher**: every `pack_versions` row in
     the app still comes out of `PublishPackDirectory`. It re-validates on the
     way — cheap check before an irreversible act, and the assets could have been
     replaced or re-mapped since. Pack cover and book cover are both page one's
     display art (one blob, two `assets.kind` rows). Edits after a publish
     accumulate as draft state until the next press, which is v2, never a rewrite
     of v1.
  - **`MappingRunner` is the only seam**, and exists solely because a shell-out
    is not testable on a box with no engine. `GodotMappingRunner` builds
    `<godot> --headless --path <project> --script tools/generate_region_map.gd
    -- <mapping source> [--display <page>] [flags]`, passing every tunable
    explicitly so a run is reproducible from the summary the pipeline prints; a
    missing or unconfigured binary is a *failed run with a sentence*, never an
    exception, so a box with no engine shows "no headless Godot is configured
    here" on the page instead of 500ing with a row stuck at `running`. There is
    no PHP mapping code anywhere and there must never be. Tests bind
    `Tests\Support\FakeMappingRunner`, which drops pre-baked
    `tests/Fixtures/pages/<case>` artifacts into the paths a real run would have
    written; `QUEUE_CONNECTION=sync` means the job runs inline, so a page that
    came back from an endpoint has really been through staging → run → store →
    validate.
  - Config: `coloringbook.godot_binary` (**null by default**) plus an
    `authoring` block — `godot_project` (defaults to the sibling `../godot`),
    `mapping_script`, `mapping_timeout_seconds`, `queue`, `max_image_kb`, and
    `tuning`, the pipeline's own flag defaults pinned server-side with optional
    per-page overrides in the same vocabulary (so a page tuned in the browser can
    be re-run by hand on the dev box with the same flags).
  - UI: `admin/Books.vue`, `admin/Book.vue`, `admin/AuthoredPage.vue` (the page
    editor: mapping state, the §10.1 region-overlay preview via
    `PackPreview::renderPair()`, the validation report in plain language, the
    tuning form and the pipeline output). Sidebar gained a **Books** entry,
    admin-only like the rest.
  - Tests: **417 → 471** (`composer test` green: pint + phpstan level 7 + pest;
    470 passed, 1 skipped — the opt-in Godot integration test). Dusk **33 → 40**,
    all green, `tests/Browser/AuthoringTest.php`. The engine integration test is
    opt-in via `COLORINGBOOK_GODOT_BINARY` and was verified against the real
    4.5.1 binary on the dev box; it is also the check to run when the pinned
    engine on the mini-pc moves.
  - Still open: `COLORINGBOOK_GODOT_BINARY` has to be set in the mini-pc's `.env`
    (with a pinned engine and a queue worker with a real memory limit for 2048²
    images) before web-authored pages can map there — until then the editor
    reports "no headless Godot binary is configured on this server" and refuses
    to publish, which is the intended behaviour rather than a failure.

### BL-25: All coloring books served by the server — none baked into the app — `done`
Logged 2026-08-07. A shipped build must contain **no coloring books**: the
shelf is populated from the server catalog plus whatever is installed in
`user://dlc`. Books stay in the repo only as dev/editor fixtures and as
pack-build inputs.
- **Exclude, don't delete.** The release export excludes the built-in books
  (`resources/books/*`, `assets/books/*`) via the export preset's filters
  rather than removing them from the repo: dev smokes and the editor keep the
  test book and the coyote fixtures, and `BookDef.discover()` is unchanged —
  its `res://` scan simply finds nothing in a shipped build, and the WP7
  de-dupe (built-in wins) keeps dev behavior sane. This also closes the
  Campaign-2 follow-up "the debug Test Book ships in the release build".
- **BL-19 is a prerequisite.** The web build cannot install any pack until the
  download stall is fixed — an all-server shelf would otherwise be empty on
  the primary test surface (the port-91 site). Fix BL-19 first (both the pack
  download in `pack_installer.gd` and the paint pull in `sync_queue.gd` use
  the stalling `max_redirects = 0` pattern).
- **Empty-shelf UX.** First launch with nothing installed must not dead-end:
  the shelf shows the catalog (`GET /packs` is optional-auth, so it renders
  signed-out), and free packs need a signed-in device to download
  (entitlement auto-grant, §9) — signed out, the Get flow must lead the
  grown-up to the adult gate/sign-in rather than failing silently. Offline
  with nothing installed shows a friendly "connect to get coloring books"
  state, never a spinner (offline-first, §8.2 — no screen awaits a request).
- The shipped coyote content is the already-published `coyote-book` pack
  (book_uid `coyote-2026`); the save/progress key is the uid, so a book
  colored from the built-in copy continues seamlessly from the DLC copy.
- Affected: `godot/export_presets.cfg` (exclude filters, all presets),
  `scripts/backend/pack_installer.gd` + `sync_queue.gd` (BL-19),
  `scripts/screens/book_select.gd` (empty/signed-out states),
  `scripts/resources/book_def.gd` (only if discovery needs a guard),
  dev smokes (a release-shaped discovery check), `docs/DESIGN.md` §3.4,
  `docs/DLC_SERVER.md` §8.1.
- Done. **Two lines of `export_presets.cfg` and the shipped build has no books
  in it.** Both presets (Android and Web — there are only two) now carry
  `exclude_filter="resources/books/*, assets/books/*"`, which subsumes the old
  `assets/books/*/source/*`. Nothing was deleted and nothing `preload()`s a
  book, so the editor, the pack-build tool and all seven dev smokes are
  untouched.
- **Proved from the `.pck`, not from the export log.** A Web release exported to
  a scratch directory (never `build/web`, never deployed) and its file table
  parsed by hand:
  ```
  before  197 files, 1 449 744 B   5 resources/books/* remaps, 2 exported
                                   book.res, 10 assets/books/* (.import +
                                   regions JSON), 7 page .ctex (≈584 KB)
  after   170 files,   836 256 B   ZERO of the above; the only "book" strings
                                   left are book_select / book_cell / book_def,
                                   which are code
  ```
  The build boots clean in Chrome from that very `.pck` (engine banner, WebGL2,
  no warning, no error) — including no complaint about the missing books root,
  because `BookDef.discover_builtin()`'s "root does not exist" `push_warning`
  became a `print_verbose`. That is the only line of discovery that moved: an
  absent `res://resources/books` is now the DESIGNED state of a release, and a
  warning printed on every shelf build for the designed state is a warning
  nobody will read when it means something.
- **The empty-shelf dead end was real, and it was in three places.** With no
  books baked in, a first launch is signed out with an empty shelf, and all
  three of these had to change before that was survivable:
  1. **"More books" was hidden until you signed in** — on the old argument that
     a shop a grown-up cannot use is confusing. That argument dies with the
     built-in books: the shop is now the ONLY way a shelf ever gets a book, so
     hiding the way in leaves a screen with nothing on it to press. It is shown
     whenever the build has a server (`Backend.is_enabled()`).
  2. **`Backend.fetch_packs()` refused to run signed out**, so the catalogue the
     server is happy to serve was never asked for. `GET /packs` is optional-auth
     precisely for this (§7.4 "the shop window"); it needs a server, not an
     account. Signed out every row simply comes back `owned: false`.
  3. **A Get pressed signed out failed with a code nobody asked to see.** The
     shop now raises `sign_in_requested`, `main.gd` answers with the adult gate
     → account panel, and the shop refreshes behind it on `auth_changed`. The
     row is deliberately left in its confirm state, so coming back from the gate
     the grown-up is still looking at "Yes, download". Free packs still need a
     signed-in device — the entitlement is granted to one (§9) — so the sign-in
     is asked for at the moment it is actually needed rather than as a
     precondition for looking.
  The shelf's own empty label stopped being `"No books found under
  res://resources/books/"` (a developer's sentence on a child's screen) and
  became "No coloring books yet. A grown-up can tap "More books" to add some.",
  or just "No coloring books yet." in a build with no server. **Offline with
  nothing installed is already right and stayed that way**: the shop renders
  what is on disk immediately, the `GET /packs` answer patches it when it lands,
  and when it does not the overlay says "Could not reach the server. The game
  works fine without it." No screen awaits a request, no spinner, no modal, and
  the child sees none of it (§8.2).
- **Progress continuity is asserted, not assumed** (`dlc_smoke` check f, now the
  BL-25 scenario end to end): a page is erased and re-coloured through the
  BUILT-IN coyote and a paint layer written against it, then the pack twin that
  claims `coyote-2026` is asked — same save key, same status, same resume index,
  the same PNG bytes on disk. Then the release shape itself: `discover()` over a
  books root that does not exist returns exactly the installed packs, every one
  of them runtime, still carrying that progress — and with nothing installed
  either it returns an empty array rather than an error.
- Smokes: **dlc 90 → 99**, **backend 165** (check (b) grew the signed-out shop
  window: `GET /packs` with no account, nothing marked owned, the overlay
  rendering rows, its status line, and a Get raising the sign-in request instead
  of installing), paint 47 / palette 146 / flow 159 / shell 142 / mobile 141
  unchanged, **sync 87/87** (see BL-19).

### BL-26: Client-side delta pack updates — download only the changes — `done`
Logged 2026-08-07. The server half has existed since WP3: the manifest's
per-file sha256 `files` map (§7.2) and the entitled
`GET /packs/{slug}/files/{path}` route were built *for* delta updates. The
client installer currently downloads the whole `pack.zip` on every install
AND every update. Implement the update path as a per-file delta:
- On an **update** (installed version > 0 and < latest): fetch the new
  manifest, diff its `files` map against the installed tree. A file whose
  sha256 matches the installed copy is **copied** from the installed pack
  into `.incoming` (no download); a changed or new file is fetched via
  `/packs/{slug}/files/{path}`; a file absent from the new manifest simply
  isn't carried over (deletion falls out of the diff).
- Everything downstream is unchanged: every sha in `.incoming` is verified
  exactly as today, the swap is atomic, and it never applies mid-page.
- **First installs keep the single-zip path** — a delta against nothing is
  the archive, and one zip beats N requests.
- **Progress totals reflect reality**: total bytes = the files actually being
  fetched, so a one-page fix on an 8 MB pack reads as ~600 KB, not 8 MB.
- **Failure falls back, never fails harder**: if any per-file fetch or the
  diff itself goes wrong, fall back to the full-zip path — the delta is an
  optimization, not a new failure mode.
- Works on web and native alike (BL-19's web redirect handling applies to
  the files route the same as to the archive route).
- Affected: `scripts/backend/pack_installer.gd`, possibly `api_client.gd`,
  dlc/backend smokes (a delta case: publish a v2 changing one file, assert
  only that file's bytes travel and the result is byte-identical to a full
  install), `docs/DLC_SERVER.md` §7.4 (note the as-built client behavior).
- Done, client-only; the files route and its tests were already there. `_install`
  now picks a route and both routes end in the same place:
  ```
  _can_delta()      installed > 0 AND pinned > installed AND the dir is there
  _install_delta()  hash the installed tree against the NEW manifest ->
                    copy list + fetch list, copy, fetch, done
  _install_archive() the old path, verbatim: 302 -> pack.zip -> unzip
  ...then, for both: verify EVERY sha256, write manifest.json, one atomic rename
  ```
  On the real fixture (`coyote-book` v1 → v2, one changed `book.json`) an update
  now moves **567 bytes instead of 993 KB — 0.1 %**.
- **The diff is the manifest against the bytes on disk, not manifest against
  manifest**, and that is the one real design decision in here. Comparing the two
  manifests would trust the installed one: a file a previous crash truncated still
  has a perfectly good entry in the old manifest and would be carried into the new
  install as if it were fine. Hashing what is actually there costs one read per
  file, cannot be wrong, and is the *same* hash `verify_files()` applies afterwards
  — so a corrupted file simply joins the fetch list and the delta repairs it for
  free. A file the new manifest no longer lists is never copied and never fetched:
  **deletion falls out of the diff** and needed no code.
- **A same-version reinstall deliberately stays on the archive.** The entry scoped
  the delta to updates, and a reinstall of the version you already have is what a
  repair looks like — the one case where re-fetching is the point.
- **Three fallback triggers, one behaviour: take the archive, say nothing.**
  (a) the diff refuses a manifest path that is not zip-slip-safe, (b) any copy or
  any per-file fetch fails, (c) **the delta-built tree fails verification** —
  which is checked inside the delta branch as well as at the shared gate, because
  a tree the new manifest disowns is a delta gone wrong and must mean "take the
  archive", never "this pack failed". The redundant pass is the price of the
  guarantee that the delta cannot fail an install the archive would have finished.
  `_install_archive()` starts by deleting `.incoming`, so a half-built delta tree
  is never something the archive path has to reason about, and the caller is told
  only which route won.
- **Progress counts what is actually travelling.** The per-file callback is
  rebased on the bytes already done and reports against the delta total, so the
  row reads "567 B of 567 B" rather than crawling across a 993 KB scale and
  looking broken. `KEY_MODE`, `KEY_FETCHED_BYTES`, `KEY_FETCHED_PATHS` and
  `KEY_COPIED_FILES` joined the result dictionary (and its failure shape) so the
  route a install took is a fact a caller can read rather than infer.
- **Both platforms, for free**: `_download_pack_file()` uses BL-19's
  `ApiClient.can_read_redirects()` split exactly as the archive does — native
  reads the `302` and fetches the signed URL with `auth: false`, web asks the
  authorised route and lets the browser follow. Pack paths have slashes in them
  (`books/coyote-2026/page_01.png`) and the route is `{path}` `.*`, so
  `encode_pack_path()` percent-encodes each segment and leaves the separators
  alone — encoding those would address a file that does not exist.
- **The smoke publishes a real v2 and watches the wire** (`backend_smoke` check m,
  15 assertions). It needs two published versions of the fixture pack, which is
  not a test fixture but the actual workflow (versions are server-assigned and
  immutable, §7.3): publish the directory, then publish a copy with one file
  changed. The check computes what differs *from the two manifests* rather than
  hardcoding it, then: v1 installs from the archive; a sabotaged delta
  (`fail_next_delta_fetch()`, a documented dev seam beside
  `GameState.set_autosave_interval`) falls back to the archive and still installs
  v2 — **and that archive install is the reference tree**; v1 goes back on; the
  update runs as a delta fetching exactly the one changed path and exactly its
  567 bytes, copying the other four; the progress total is the delta's size; and
  the delta-built tree is compared **file for file, sha256 for sha256** against the
  reference. Two installs of each version, one reference, both halves of
  "byte-identical" proved against it.
- Smokes: **backend 165 → 180**; paint 47 / palette 146 / flow 159 / shell 142 /
  mobile 141 / dlc 99 / sync 87 unchanged.
- Left open: the fallback trigger (c) — a delta tree that fails verification — has
  no test of its own, because there is no way to make a correct copy produce wrong
  bytes without a second seam. It shares its entire code path with trigger (b),
  which is tested.
- Dev-server note: this round published **`coyote-book` v2** on the local dev
  database. A fresh database needs the fixture published twice before
  `backend_smoke` check (m) can run; it fails with the two commands in its doc
  comment rather than skipping quietly.

### BL-27: Splash goes straight to the shelf — `done`
Playtest feedback (2026-08-07): the title screen's "tap anywhere to start" was
a gate with nothing behind it. The splash now plays a short joyful beat and
carries the player straight to the bookshelf with no tap required.
- Done 2026-08-07. The intro is a ~1.95 s beat: paper springs up → the 12
  title letters pop in one at a time, unwinding a small twist as they land →
  crayons slide up from below the shelf, centre first, fanning open → the
  scribble draws itself lane by lane → the hint ("let's color!") fades in →
  short hold → `start_requested` emits by itself. One ease-out-back curve
  (overshoot 1.9) drives every pop so the splash moves as one hand. A tap
  during the beat skips to the finished frame and emits immediately; the
  signal fires exactly once either way.
- **Gotcha: the beat is a pure function of time applied per `_process` frame,
  not tweens** — `_apply_responsive_layout()` rebuilds the lettering when the
  font size changes (all but guaranteed on the first layout pass), and a tween
  holding a freed Label is a crash. Scale/rotation on container-managed nodes
  are written with `set_deferred` because `fit_child_in_rect` resets both.
- Harness hook: static `TitleScreen.autostart_enabled` (a static because the
  harness must decide before `Main._ready()` instantiates the title);
  shell/mobile/backend smokes set it false. New shell_smoke check (a2) proves
  an untouched splash emits on its own, only after the beat, exactly once.
- New API: `skip_intro()`, `is_intro_playing()`; `get_tap_button()` etc.
  unchanged. Signal-up architecture untouched — main still just listens.

### BL-28: The bookshelf should look like a bookshelf — `done`
Playtest feedback (2026-08-07): the shelf was a grid of dark cards on a flat
colour; the cells read as UI cards, not books. Both halves rebuilt,
primitive-drawn (no PNG art):
- Done 2026-08-07. **The room** (`shelf_backdrop.gd`, new): warm gradient wall
  (#FBE5C2→#EEB78A), light pool, seeded pastel wallpaper dots (deterministic —
  screenshots stay stable), skirting board, plank floor with seams and sheen,
  warm vignette. The header became a cream sign panel. **The bookcase**
  (`shelf_boards.gd`, new): a carcass drawn behind the grid — back panel with
  grain, one lit plank per grid row at the row's exact bottom edge, contact
  shadows under each book, top rail, plinth, end uprights. The case stands on
  the floor (SHRINK_END) instead of floating. **The books** (`book_cell.gd`):
  styleboxes emptied (the Button is input-surface only); an inner BookArt
  draws stacked page edges 9 px proud of the open side, a rounded cover, a
  21 px spine with hinge crease and binding ribs, gloss, and silhouette
  outline. Cover colour = `book.get_uid().hash()` into an 8-colour table —
  deterministic, no authoring step. Hover tips the book out (−9 px, ±2.2°,
  ×1.035); press pushes it in.
- **The boards follow the layout; they are not the layout.** `ShelfBoards` is
  the grid's sibling in a shared `MarginContainer`, reads cell rects back
  after every `sort_children`, draws one plank per row — column count, book
  count and window size need no plumbing. With no rows it draws two bare
  shelves so "no books yet" still shows furniture.
- **Gotcha: the hover lift lives on an inner Body child** — tweening the cell
  itself would move `size`/`global_position` and break harness measurements;
  hover sets `z_index`, never `move_to_front` (which changes the grid slot).
- **Gotcha: `_relayout_columns` must subtract the carcass frame (−48)** or a
  1264 px viewport fits 5 columns exactly and the frame has nowhere to go.
- Public API, `MAX_COLUMNS`, `CELL_*`, empty-shelf strings all unchanged.

### BL-29: Page toolbar polish + action feedback — `done`
Playtest feedback (2026-08-07): the top-of-page buttons were plain and the big
verbs (save, start over, undo/redo) gave no ceremony.
- Done 2026-08-07. **`ToolbarStyle` (new) is the family, not a theme**: one
  slab shape (20 px corners, 5 px darker wax lip, drop shadow) in crayon-box
  hues assigned by job — Back blue, Save green, Start over red, page arrows
  violet, history arrows teal, padlock slate/amber by lock state. Drawn-glyph
  buttons (padlock, history) borrow the identical plate via `plate()`.
  **`PopFeedback` (new)**: every toolbar button squashes 0.94 on press and
  springs back BACK-eased; drives only scale/rotation about the centre, so
  container layout and `get_global_rect()` assertions are untouched.
  **Save flourish**: button pops, sparks fly (`SparkleBurst`, new), the
  "Saved!" toast bounces in with stars — flourish is opt-in per call site, so
  "Page locked"/"Saving…" and the silent interval autosave stay plain.
  **Start over**: `FreshSheetWipe` (new) — clean paper slides in from the
  left with a shadow band and bright rim, blooms as it lands, fades to reveal
  the blank page; plays from `restart_current_page()` after the clear, so any
  path that clears a page gets the fresh sheet and the confirm overlay logic
  is untouched. **Undo/redo**: `HistoryButton.play_press()` pops, tips in the
  arrow's direction, and sheds three sparks in-`_draw` at the moment
  `history_applied` says the paint actually changed; a disabled button never
  animates.
- Depth is tree order, not `z_index`: the new full-rect `Effects` layer sits
  after `Celebration` and before `PageFlip` — over the toolbar, under the
  flip and confirm overlay for free.
- **Gotchas**: pressed styleboxes must keep identical content margins (a
  margin change on press re-lays out the row under the finger);
  `PackedColorArray(...)` is not a constant expression but
  `const X: Array[Color]` is; a script can't reference its own `class_name`
  in a static when the global class cache is stale — self-`preload` const
  instead, and every cross-file reference to the new classes preloads.
- Mechanics boundary held: PageView / paint_canvas / coverage_tracker /
  stroke lifecycle / save timing / undo stacks untouched; all effects are
  `MOUSE_FILTER_IGNORE` and self-freeing.

### BL-30: Opening a book, and a richer page flip — `done`
Playtest feedback (2026-08-07): the shelf→page swap was instant, and the BL-4
curl was visually plain.
- Done 2026-08-07. **Opening/closing** is a `main.gd`-owned overlay
  (`BookOpenTransition` inner class, primitives only): the book dips
  (BACK/EASE_IN anticipation) and flies to fill the screen in 0.24 s, the
  screen swap happens behind it, the cover swings open on its spine over
  0.34 s — vertical pinch fakes the rotation, a gradient shades the turning
  face, a shadow travels ahead, a white page spread fades into the real page
  (~0.6 s total). Leaving a book is the mirror (`Transition.BOOK_CLOSE`); the
  cover carries a three-stroke crayon doodle in live palette colours
  (injected, not read off the autoload). Deliberately a *generic* book — main
  is handed a `BookDef`, never a cell's rectangle, so no shelf coupling.
  `_show_screen()` is now `(scene, id, transition, setup)` — setup moved last
  to keep the multi-line lambda parseable.
- **The flip polish rode entirely on shader uniforms that already existed**
  (`page_curl.gdshader` untouched): curl_radius swells 0.055→0.135 with the
  lift, fold_tilt leans 0.17→0.05 (the straight sweep becomes an arc),
  shadow deepens and softens with stand-off, back_bleed rises. The settle is
  a code-built `SettleShade` child in the last 16% of the duration — a damped
  `(1-t)·|cos(1.5πt)|` drop-bounce shadow — carved out of the existing
  duration, so a flip still takes exactly `duration` and `flip_finished`
  timing is unchanged. Progress-0 stays pixel-exact pass-through.

### BL-31: Downloads should be fun to watch — `done`
Playtest feedback (2026-08-07): a pack download in "More books" was a bare
ProgressBar.
- Done 2026-08-07. **`wax_progress.gd` (new)**: a self-contained strip drawn
  from primitives — a wax ribbon fills from the left with sine-wobbled edges
  (stationary in space, so laid wax sits still) and grain streaks, a 34 px
  crayon rides the head, scribble-bobbing and shedding up to 12 wax crumbs as
  bytes arrive, a dashed guide line marks the not-yet-coloured remainder.
  Unknown total = a fixed-length smear sliding back and forth
  (smoothstep-eased turnarounds). Completion: the stroke snaps full, a
  5-point star pops at the finish line, the crayon hops off, 18 confetti bits
  burst, the strip fades (1.2 s). Per-pack colour = slug hash into the
  palette, stable across sessions.
- **The strip is a second rendering of the bytes, never a second source of
  truth**: `get_progress_ratio()` returns the value `set_downloading`
  computed, synchronously; only the drawn head eases (`1-exp(-9·dt)`).
  backend_smoke gained 9 assertions incl. "10 frames of easing don't move the
  ratio". The animation hangs off `_set_state` by one added call knowing
  three transitions (begin / celebrate / stop) — deleting the strip and
  restoring the ProgressBar would be a purely local edit.
- **Gotchas**: no `class_name` on the new script on purpose (the global class
  cache only regenerates in the editor; `PackShop` preloads it into a const,
  which resolves as a type hint from the inner `PackRow` too). Confetti must
  burst from the finish line, not the eased head (the last chunk lands while
  the stroke is still catching up). `--check-only --script` can't validate
  anything touching an autoload — use a throwaway scene in project mode.
- The row grows 14→48 px while downloading (intentional — draws the eye),
  and the strip hides itself once the confetti lands.

### BL-34: Cycle-left / cycle-right arrows at the strip's ends — `done`
Logged 2026-08-07 (playtest: the crayon-box carousel only ran forwards, so
overshooting the box you wanted cost a full lap). Done 2026-08-07 together with
BL-33, which depends on where the arrows land.
- **`CrayonCycleButton` (new, `scripts/components/crayon_cycle_button.gd`)**,
  one at each OUTER END of the strip's long axis, replacing the single
  forward-only `CrayonBoxButton` tile. Primitive-drawn like everything else in
  this shell. It is a **bar**, not a tile — `THICKNESS` 68 px across the strip's
  long axis, stretching along its short one — because a bar costs the crayons the
  least length, and length is the entire currency of BL-33's fit.
- **Where they sit, and why it is not symmetric.** `Body` is
  `[Controls, Scroll, CycleNext]`: the LEADING bar shares the tool band
  (`Controls`) with the `IntensityButton`, the TRAILING one caps the far end
  alone. The obvious symmetric layout — a band of its own at each end — costs the
  strip 88 + 88 px of length instead of 88 + 68, and at the smallest landscape
  canvas that difference is the whole margin between "two ranks of 65 px crayons"
  and "does not fit, scroll after all". Both bars are still at the two outer ends
  of everything on the strip, which is what the smoke asserts (`_ends_of`:
  nothing — crayon or tool — starts before the back bar or ends after the forward
  one).
- **Both are OUTSIDE the crayon `ScrollContainer`**, the BL-2/BL-23 rule
  preserved: a slide-to-select gesture can never land on a tool.
- **Each bar previews the box IT would fetch**, as a segmented colour stripe
  along its outer edge — the opposite convention from the tile it replaced, and
  deliberately: a two-ended carousel's arrows answer "what happens if I press
  this", while "where am I" moved to the pips and the flash below.
- **`PaletteChild.prev_crayon_set()`** beside `next_crayon_set()`. A backward
  cycle is byte-for-byte the same event as a forward one: first crayon, own
  colour, colours face, exactly ONE resolved `color_picked`, and the brush never
  moves. `PaletteDef.wrap_crayon_set()` needed no code — `wrapi` already wraps
  negatives — but it is documented and asserted now, because "the cycle has a
  back end" is a contract, not an implementation detail.
- **Where the box's identity went.** The carton tile was the only thing that drew
  "which box is out". It is replaced by two cheaper things:
  1. **Pips on both bars** — one per box, current filled. Always visible, says
     "box 2 of 6" without a number.
  2. **`CrayonBoxFlash` (new, `scripts/components/crayon_box_flash.gd`)** — a
     transient banner that pops over the strip on every cycle, shouts the name
     ("Neon!") over a row of that box's colours, and takes itself away: pop
     0.22 s (overshooting), hold 0.85 s, fade 0.45 s. Same shape as the BL-11
     celebration, and the same rules — `MOUSE_FILTER_IGNORE`, absolute z, blocks
     nothing, and hides itself on `APPLICATION_FOCUS_OUT` /
     `WM_WINDOW_FOCUS_OUT` / `EXIT_TREE` (the web tab-switch case where no tween
     ever runs again). Anchored full-rect over the palette and drawn about its
     own centre, so it lands in the middle of the strip in both docks with no
     placement code, and it scales itself down rather than run off a narrow one.
     A permanent name label was rejected: it is a slab of text on a strip built
     for a child who cannot read yet. Transient, it is a firework.
- **The old tile is deleted**, and the palette smoke asserts
  `crayon_box_button.gd` is gone, so bringing it back has to be a decision
  somebody takes on purpose.
- **The "two 88 px tiles share the short axis, a third overflows silently"
  gotcha from BL-23 is obsolete** — that geometry is what this entry reworked.
  The smoke's tile-fit block was rewritten around the new ends rather than
  contorted to keep the old assertions green.
- Affected: `palette_child.gd`, `palette_def.gd` (docs), new
  `crayon_cycle_button.gd` + `crayon_box_flash.gd`, deleted
  `crayon_box_button.gd`, palette smoke.

### BL-33: Landscape column must show every crayon — no scrolling — `done`
Logged 2026-08-07 (playtest: on a horizontal display the docked crayon column
scrolled). BL-21 shipped that scroll as a known trade — "a BL-23 set can be any
length" — and this entry reverses it for the shipped lineup. Done 2026-08-07,
after BL-34 because the arrows decide how much length is left.
- **The arithmetic that forced the design.** The smallest landscape logical
  canvas is 1152x648 (`canvas_items` + `expand` keeps the base size as a floor on
  both axes, so the landscape SHORT axis is the constraint). Minus the coloring
  toolbar and the strip's margins, the docked column has ~530 px of length. Ten
  crayons at the 64 px touch floor need 640 px + gaps **before** the tools are
  paid for. One rank is therefore not arithmetically possible: **wrapping is not
  a fallback here, it is the answer**, and the only open questions were how many
  ranks and how wide the strip has to be to make them look like crayons.
- **`PaletteChild._fit_crayons()`** — the whole fit, run on every rebuild, layout
  flip and resize:
  1. Budget the long axis: the strip's own rect, minus the tool band, minus the
     end bar, minus the separations. Every term is a **constant**
     (`STRIP_MARGIN`, `BODY_SEPARATION`, `CRAYON_SEPARATION`, the sections'
     `get_combined_minimum_size()`), never a measured rect — a fit that read a
     stale rect would oscillate. `BODY_SEPARATION` is applied to the scene's
     containers *from the script*, so the number the budget uses and the number
     the container uses cannot drift.
  2. For ranks 1..`MAX_RANKS` (3), pitch = `(along − gaps) / per_rank`,
     length = `(across − gaps) / ranks`. **The fewest ranks that clear the floor
     on both axes wins** — one long rank reads better than two short ones, so an
     extra rank is a concession, not a goal.
  3. Clamp: never below `CrayonButton.MIN_TOUCH_TARGET` (64, non-negotiable),
     never above `DEFAULT_SIZE`, and never longer than `CANONICAL_ASPECT` (2.59)
     relative to its own width — a crayon squeezed towards a square stops reading
     as a crayon.
  4. If nothing clears the floor, keep the **least-bad** candidate (max of
     `min(pitch, length)`) and only then set `_overflowing`, which is the one
     thing that re-enables scrolling. A strip one pixel too short ends up a hair
     under the floor, not falling off a cliff into three ranks of slivers.
- **Shipped outcome**: portrait row = 1 rank of full-size crayons (unchanged);
  docked column = **2 ranks of 5**, 65.6 px pitch at the worst canvas and 68 px
  (full size) at any taller one. `ScrollContainer` modes are `DISABLED` in both
  docks; the scroller stays as the crayons' host and as slide-to-select's hit
  area, it simply has nothing to scroll. Crayons fill each rank in palette order
  before starting the next (nested `BoxContainer`s, not a `GridContainer`, which
  fills row-major and would zig-zag the colour order a child is learning).
- **`CrayonButton` is resizable now**: `canonical_size`, and `LIFT_PX`,
  `LIFT_HEADROOM`, `TOP_PAD`/`BOTTOM_PAD` and the press sink are all multiplied
  by `length_scale()` (drawn length ÷ `DEFAULT_SIZE.y`). A shrunken crayon is the
  same crayon smaller, not a full-size one with its head cut off — and the
  invariant BL-16 bought survives at every size: `lift_headroom() >=
  resting_lift() * SELECT_BOUNCE_SCALE`, so the box still reserves the bounce
  PEAK and the scroller can never slice the one frame the animation exists for.
  The smoke asserts the ratio now, not the constant. The canonical-space drawing
  rule is untouched: `ORIENT_LEFT` still rotates before anything is drawn, and
  everything above is expressed in canonical space, so it followed for free.
- **The landscape column got its own thickness**: `COLUMN_THICKNESS` 260 vs the
  row's `STRIP_THICKNESS` 212. Two ranks of a 212 px strip are 89 px crayons —
  measured on screen, they read as coloured nubs. 260 buys 113 px ranks and the
  silhouette back, out of the axis a landscape screen has most of. Portrait,
  which has neither the problem nor the room, is untouched. (BL-21's "one number
  for both" is therefore retired; the backlog entry sanctioned it explicitly.)
- **Gotcha**: the fit is measured against a *worst-case* toolbar (96 px, vs the
  ~74 px `coloring_page.tscn` actually produces), so the shipped margin is bigger
  than the smoke's. Do not spend that margin without re-running check 5e — at the
  smallest canvas the crayons land at 65.6 px against a 64 px floor, and the next
  thing under the floor is a third rank that does not fit either.
- Smokes: **palette 146 → 184** with BL-34. The BL-23 tool-tile block became a
  fit block: every crayon AND every tool inside the strip's rect, nothing
  scrolled, in all three layouts; plus a new **check 5e** that instantiates
  throwaway palettes into strips of exactly the docked-column size at the
  smallest supported landscape canvas (and the row at 1152, and a tall column)
  and holds each to "all ten crayons, inside the strip, none below the floor,
  both cycle bars still capping the ends, nothing scrolls in either direction".
  **mobile 141 unchanged** with one assertion inverted: the portrait row now fits
  rather than scrolls. paint 47 / flow 159 / shell 151 unchanged.
- Affected: `palette_child.gd`, `crayon_button.gd`, `coloring_page.gd` (a stale
  doc line), palette + mobile smokes.
