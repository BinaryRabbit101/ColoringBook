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

### BL-8: DLC support + backend server — `server + client integrated` (2026-08-06; Phases 0–5 of docs/DLC_SERVER.md §12)
Longer-term: introduce DLC coloring-book packs. Backed by a (most likely
Laravel) server handling:
- user accounts and cloud-synced game saves
- DLC entitlement/delivery
- uploading and managing coloring books and pages (admin tooling that feeds
  the region-mapping pipeline)
The Laravel app lives at `server/` (see `server/CLAUDE.md` and
`docs/SERVER_BUILD_PLAN.md`): accounts/auth/parent dashboard, progress sync,
catalog + free-pack DLC delivery, paint-layer sync, admin upload/validation/
preview/publish. 416 tests green. Still open: Phase 0 client work (`book_uid`,
save v2, `user://dlc` discovery, runtime textures), payments (Phase 6), and
deploy to the mini-pc.
- Affected: `server/` (Laravel app in this repo), `docs/DLC_SERVER.md`,
  `docs/SERVER_BUILD_PLAN.md`

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

### BL-18: "Erase all progress" must survive cloud sync — `open`
Surfaced by the WP11 sync client (2026-08-06). "Erase all progress" (and the
per-page "Start over", BL-7) is local-only, but against a synced account the
§6.3 merge rule only ever climbs: the next pull quietly restores everything
from the server, so the erase appears not to work. That is the merge doing its
job — a save must never lose to a network race — but a grown-up pressing the
button expects it to stick. Options, not mutually exclusive:
1. **Server-side wipe from the parent dashboard** (the clean answer): delete
   the account's/profile's `book_progress` + paint rows there, where the adult
   already is; the device's next pull then has nothing to restore. Needs a
   deliberate "device pushes right back" answer — the client should reset its
   sync-queue fingerprints/revisions when it erases locally, or its next drain
   re-uploads the erased state.
2. **Client "erase and stop syncing"**: local erase also signs the device out
   (or pauses sync) so the restore never fires — cheap but surprising in the
   other direction.
Per-page "Start over" has the same shape in miniature: the erased page's paint
is deleted locally, but the server's copy wins the next LWW comparison unless
the deletion is pushed as a state (tombstone or explicit delete endpoint —
DLC_SERVER.md §11 currently has none).
- Affected: server (dashboard wipe UI + a paint/progress delete or tombstone
  path), `scripts/backend/sync_queue.gd` (fingerprint/revision reset on local
  erase), docs/DLC_SERVER.md §6.3/§11
- Decision needed before paint/progress sync ships to a real household.
