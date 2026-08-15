# Backlog — Issues & Feature Requests

First logged 2026-08-06 from playtest feedback. Status: `open` → `in-progress` → `done`.
Completed entries move, with their full done-notes intact, to
[BACKLOG_ARCHIVE.md](BACKLOG_ARCHIVE.md) — the done-notes are the project's
institutional memory (decisions, gotchas, smoke counts); nothing is deleted.

## Open

### BL-8: DLC support + backend server — `server + client integrated; only payments left` (2026-08-06; docs/DLC_SERVER.md §12)
Longer-term: introduce DLC coloring-book packs. Backed by a (most likely
Laravel) server handling:
- device identity + entitlement/delivery — bought once, owned on every device
- uploading and managing coloring books and pages (admin tooling that feeds
  the region-mapping pipeline)
The Laravel app lives at `server/` (see `server/CLAUDE.md` and
`docs/SERVER_BUILD_PLAN.md`): device registration, catalog + free-pack DLC
delivery, admin upload/validation/preview/publish, and the web authoring
surface. Deployed to the mini-pc; the client half (`book_uid`, save v2,
`user://dlc` discovery, runtime textures, `Backend`) shipped with it.
- 2026-08-07: **payments (Phase 6) deliberately deferred** — the user will pick
  the provider/pricing shape when ready; everything else in this entry has
  shipped in the meantime (deploy, DLC, authoring).
- 2026-08-09: **accounts and cloud save-sync were removed entirely** (BL-53).
  The bullets about user accounts and cloud-synced saves that used to head this
  entry are gone from the product, not merely deferred; `user://` is the whole
  persistence story. What is left open here is **Phase 6 alone**: a real
  `StoreReceiptVerifier`, a Play Billing plugin behind
  `Backend.get_store_receipts()`, and the Gradle build that a plugin needs
  (docs/ANDROID.md).
- Affected: `server/` (Laravel app in this repo), `docs/DLC_SERVER.md`,
  `docs/SERVER_BUILD_PLAN.md`

## Completed — awaiting archive

### BL-53: No accounts — the device is the identity — `done` (2026-08-09)
Product decision, taken the day after BL-52 shipped and superseding half of it:
**manual account registration and login are gone.** Every install auto-signs-in
through `POST /api/v1/device/register` (find-or-create by `device_uid`), and
that is the whole of who anybody is. No parent accounts, no sign-in screen, no
account linking, no child profiles, no cloud save-sync. Local on-device saving
is unchanged and is now the sole persistence. The admin web login and the pack
publishing flow did not move at all.

BL-52 had already proved the load-bearing half — the store account, not ours, is
what carries a purchase between a household's devices. Once that is true, an
account buys the product nothing and costs it a PII footprint, a consent story,
a deletion story and a merge algorithm.

**Server.**
- The `Device` row **is** the identity: Sanctum tokens are minted on it
  (`Device` is `Authenticatable` + `HasApiTokens`), so `$request->user()` is a
  `Device` on every game route. `users` is an operator/admin-only table.
  `App\Services\EntitlementOwner` deleted; entitlements are owned by
  `entitlements.device_id` and nothing else.
- Routes removed: all `/auth/*` (register, token, refresh, sign-out), `GET /me`,
  all `/profiles`, all `/sync/*` (progress, paint, paint-blob). Web:
  `settings/{profiles,devices,pictures,progress}`, `DELETE settings/profile`,
  the passkey well-known, and Fortify's register / email-verification /
  two-factor / passkey routes.
- Tables removed: `child_profiles`, `book_progress`, `paint_layers`,
  `retained_paint_layers`, `shelf_erasures`, `passkeys`, the `two_factor_*`
  columns, `devices.user_id` / `owner_key`, `entitlements.user_id` /
  `owner_key`. **Squashed into the original `create_*` migrations** rather than
  added as a drop round — nothing is deployed that needs the intermediate
  states.
- `devices.device_uid` is now **globally** unique (no account to scope it
  inside). `entitlements` is `UNIQUE(device_id, pack_id)` and
  `UNIQUE(device_id, platform, platform_txn_id)` — **per-device receipt
  uniqueness is deliberate**, so the same store receipt grants on every device
  that presents it. That is the entire restore-purchases mechanism, and Google
  Play requires non-consumables to be restorable.
- `POST /device/register` is **byte-for-byte the contract BL-52 shipped**:
  `{device_uid, device_name, platform}` → `{token, abilities, expires_at,
  device:{ulid}}`, `throttle:6,1`, abilities exactly
  `["entitlements:read","packs:download"]`. `save:sync` no longer exists
  anywhere. **No refresh route**: a `401` is answered by registering again.
- Final API surface: `device/register`; packs index/show/cover;
  manifest/download/files (public if free, else token + `packs:download` +
  entitlement); the signed archive/file routes (`X-Accel-Redirect`);
  `GET /entitlements` and `POST /entitlements/verify`. `/api/v1/admin/*` is
  unchanged except that `POST /admin/entitlements` now addresses a
  **`device_uid`** (`DEVICE_NOT_FOUND` instead of `USER_NOT_FOUND`) — the only
  handle a player has. Web: `/admin/*`, `/login`, `/dashboard`,
  `settings/{profile,security,appearance}`, admin session only.
- Paint disk, the `paint:prune` schedule and `PaintStorage` are all gone.
- **PII: players have none.** The operator's email is the only address stored,
  and nothing a child makes ever leaves the device — which makes the COPPA
  posture an argument nobody has to have.

**Client (Godot).**
- `sync_queue.gd` deleted (`user://sync_queue.json` is orphaned — nothing reads
  or writes it), along with `account_panel` and the sync smoke.
- `auth_store.gd` rewritten: `user://auth.json` schema **v2**, device-only
  (`{device_uid, device_name, token, abilities, expires_at}`); a v1 file is
  migrated by keeping **only** its `device_uid`.
- `Backend`: `sign_in_device()` on startup — silent, fire-and-forget, degrades
  to offline; `_authed()` replays a request **exactly once** after re-registering
  on a `401`; `restore_purchases()` + `get_store_receipts()` are the
  billing-plugin seam; `Backend.DEVICE_ABILITIES` pins the contract for
  harnesses; `Backend.autostart_enabled` is the dev hook that stops a smoke
  registering the developer's real device. Backend's `user://` carve-outs are
  now two: `auth.json` and `dlc/`.
- The entitlements cache lost its account key — `EntitlementsStore.store()`
  takes rows only.
- Shop: a paid, unowned row shows **"In the store"** (`STATE_PURCHASE`) rather
  than offering a download the server would refuse. Settings' Account row is now
  **Purchases → Restore**, behind the `AdultGate` — which guards money now
  instead of accounts.
- Local `user://` saving is untouched.

**What this costs, stated plainly**: a drawing lives on the device that made it,
a second tablet starts with an empty shelf of the same books, and uninstalling
loses the artwork (`user_data_backup/allow` is `false` — see docs/ANDROID.md,
which now flags that as the deliberate place to revisit). What is *bought* is
portable; what is *drawn* is not.

- Docs reconciled the same day: `docs/DLC_SERVER.md` §1–§6, §7.4, §8, §9, §11,
  §12, §13 (§4 is now identity, §6 is local-only saves, §6.1/§6.3 keep their
  numbers because code comments cite them); `docs/SERVER_BUILD_PLAN.md` gained a
  2026-08-09 Decisions block that supersedes the design doc's account and sync
  sections, with the historical work packages left as written;
  `docs/DESIGN.md` §2/§3.5; `docs/ANDROID.md`.
- Affected: `server/` (models, migrations, routes, actions, services, tests),
  `server/CLAUDE.md`, `godot/autoload/backend.gd`,
  `godot/scripts/backend/{auth_store,api_client,entitlements_store}.gd`,
  `godot/scripts/components/{settings_panel,adult_gate,pack_shop}.gd`,
  `godot/scripts/dev/*_smoke.gd`, `docs/*`.

**Verification pass, 2026-08-15** — the harnesses re-run end to end on a rebuilt
dev server (`migrate:fresh` + `db:seed`, coyote v1/v2, a paid `starter-stickers`
with a Play SKU, the fake verifier). `composer test` 336 green;
**backend 190/190, dlc 139/139, shell 200/200, mobile 126/126, flow 279/280**
(its one red is the child `palette_smoke`, the known windowed-focus flake — the
same two input checks fail standalone too and neither is anywhere near this
work). Four harness defects found and fixed, none of them in the product:

- **`/device/register` carries `throttle:6,1`, and that limiter is now
  load-bearing in a way it was not when it guarded `/auth/*`.** A device-only
  design registers on launch, before a call on an expired token, and again to
  recover a 401 — so a run that exercises recovery legitimately trips a limit
  written for a human typing a password. Worse, the 429 is **invisible**:
  `Backend._authed()` re-registers internally and, when that fails, returns the
  *original* 401, so a full bucket reads as "recovery is broken". `backend_smoke`
  check (h) now starts by waiting the window out, and `_unthrottled()` is the one
  place the wait lives. Worth a product thought later: a household behind one NAT
  shares this bucket, and a 429 on the only auth route means no backend until
  relaunch.
- **A stale `user://dlc/entitlements.json` silently hides every runtime pack.**
  `should_hide_book()` treats *present but empty* as "the server said you own
  nothing", which is correct — but a cache left by any earlier run against a dev
  server makes `dlc_smoke`'s ring check fail with no hint why. `dlc_smoke`
  isolates its DLC root and its save, and **not** the entitlements store; that
  asymmetry is the trap. Delete the file when a runtime pack vanishes for no
  reason.
- **Two assertions were wrong rather than the code.** The paint round-trip
  compared a decoded pixel to an authored `Color` with `is_equal_approx`, which
  no 8-bit PNG can satisfy (0.9 stores as 230/255 = 0.902) — it now compares at
  the file's own 1/255 resolution. And the shop's "rows keep their state while
  put away" pinned the literal `STATE_AVAILABLE`, which stopped being that row's
  state the moment `STATE_PURCHASE` existed: a fixture row that is neither free
  nor owned *should* read as needing a purchase, so the check now captures the
  state before the tab switch and asserts it is undisturbed.
- Toolchain: the Godot 4.5.1 binary had disappeared from
  `OneDrive\Desktop\Godot\…`; it now lives at
  `C:\Users\binar\Documents\Godot\bin\`, off OneDrive, and the `godot` skill
  records the new path and how to re-extract it.

### BL-52: Own once, everywhere — device entitlements + public free packs — `done` (2026-08-09)
> **Partly superseded the same day by BL-53.** Decisions 1–3 below are exactly
> what the system does. Decision 4 (linking an anonymous device to an account by
> adoption) and the closing "this does NOT change artwork sync" paragraph are
> **gone**: there are no accounts to link to and no artwork sync to preserve.
> Read the word "anonymous" throughout as simply "the device" — once the account
> tier above it was removed, the tier this entry added became the only one.
> The insight that made BL-53 possible is the one this entry opens with, so the
> reasoning is worth keeping intact.

The requirement, verbatim: *"What's most important is allow the user to not need to
purchase coloring books twice between devices"* — with an explicit licence to cut
cloud artwork sync back if that is what a clean COPPA posture costs, and a product
goal of "free app content available to download without needing to create an
account."

**The design insight: the store account is already the cross-device identity for
purchases.** Play Billing's `queryPurchases()` (and StoreKit's restore) returns the
same purchase tokens on every device signed into the same store account. So the
server never needs to *own* an identity to prevent double-purchase — it needs to
verify a receipt from whichever device presents it and grant that device the pack.
No email, no password, no PII, no account.

Four decisions, each independently shippable:

1. **Free packs go public.** `GET /packs/{slug}/manifest|download|files/{path}`
   skip the token + entitlement gate when the pack `is_free` (and is in a
   downloadable status). The 302-to-signed-URL delivery mechanics are untouched —
   the signed URL was always the thing that moves bytes. The free-claim auto-grant
   (`source='free'` on first authed fetch) stays for signed-in users, so `owned`
   and `GET /entitlements` keep meaning what they mean; it is simply no longer the
   gate. A signed-out child on a fresh tablet can browse the shop and download
   every free book. Rate-limit stays on the routes; revoked-stays-revoked only
   governs the entitlement row, never public access to a free pack.
2. **An anonymous device tier — lazy, and entitlements-only.**
   `POST /api/v1/device/register` `{device_uid, device_name, platform}` (no auth,
   `throttle:6,1`) finds-or-creates an **anonymous** `devices` row (`user_id`
   NULL) for that `device_uid` and returns `{token, abilities, expires_at,
   device: {ulid}}` — a Sanctum token carrying exactly `entitlements:read` +
   `packs:download`. **Never `save:sync`**: an anonymous device can own packs; it
   can never upload a child's artwork. The client registers **lazily** — only
   when a purchase needs verifying or a restore is attempted, never on first
   launch — so a device that only ever plays free content sends the server no
   identifier at all. A `device_uid` already linked to an account is not exposed:
   register only ever scopes to the anonymous (`user_id IS NULL`) row.
3. **Receipts are the restore path.** `POST /entitlements/verify`
   `{platform, purchase_token, sku}` accepts **device tokens and account tokens**
   and writes the entitlement to whichever owner the token names. Validation goes
   through a `StoreReceiptVerifier` contract (config seam
   `coloringbook.stores.*`); until Play/App Store credentials exist the binding is
   a fake/dev verifier, so Phase 6 becomes "swap the verifier + add the billing
   plugin", not a schema change. New-device flow: install app → store returns the
   purchase tokens → client registers device → re-verifies each token → packs
   download. Bought once, owned everywhere, nobody typed an email.
   - Schema: `entitlements.user_id` becomes nullable and gains a nullable
     `device_id →devices`; **exactly one owner** per row, unique per
     `(owner, pack)` (the `profile_key` generated-column trick is the house
     pattern for NULL-proof uniqueness). `platform_txn_id` uniqueness relaxes to
     per-owner — the same purchase legitimately grants on N devices.
4. ~~**Linking is adoption, and it is optional.**~~ **Struck by BL-53** — there is
   no account to be adopted into. A device's entitlements are reached from a
   second device by re-verifying the store receipt (decision 3), which is the
   path this entry built anyway.

~~**What this deliberately does NOT change: artwork sync.**~~ **Struck by
BL-53**, which took the licence this requirement offered in full: artwork sync
is deleted rather than merely fenced off. The COPPA argument survives it and
gets shorter — the device identifier is used solely for entitlement delivery
(squarely the "support for internal operations" exemption), free play sends
nothing at all, nothing a child makes leaves the device at all, and the store
handles payment authorisation including platform parental controls.

**Client half (Godot) — shipped 2026-08-09**, then simplified by BL-53 the same
day when the account accessor it was balanced against went away:
- ~~`AuthStore` grew the second accessor~~ — the two-accessor split
  (`get_live_token()` for the account, `get_entitlement_token()` for either)
  existed to stop an entitlement-only token being handed to save-sync. With no
  account and no sync there is **one** token, and `auth.json` went to schema v2
  to say so (BL-53).
- Catalog / manifest / download / files calls carry the device token, and
  free-pack downloads work with **no token at all** — `install_pack()` dropped
  its `is_signed_in()` gate entirely (the server is the authority), and the shop
  offers Download for `is_free || owned` from the server's own flags rather than
  from "is anybody signed in".
- ~~`Backend.ensure_device_registered()` — the lazy registration seam~~;
  registration is no longer lazy, because with nothing else to identify a device
  there is no reason to defer it: `Backend.sign_in_device()` runs at startup
  (BL-53). `ApiClient.verify_receipt()` is still the Phase-6 receipt seam and
  now has UI — the settings overlay's **Restore**.
- Web build: no store, so restore is inert there; free packs are public and paid
  packs remain a Stripe question (Phase 6, unchanged).
- Smoke coverage: `backend_smoke` (b) tokenless free install + the paid refusal,
  (n) the device tier including the fake verifier, (h)
  free-installs-while-expired; `dlc_smoke` (i) the Get button's decision,
  serverless. (`sync_smoke` was deleted with sync.)

Server error codes this adds: `RECEIPT_INVALID` (422), `STORE_UNAVAILABLE`
(503, retryable), `DEVICE_REGISTRATION_FAILED` (422).
- Affected: `server/` (migrations, `routes/api/device.php`,
  `routes/api/catalog.php`, `StoreReceiptVerifier` + fake, `server/CLAUDE.md`),
  `godot/scripts/backend/{auth_store,api_client,entitlements_store}.gd`,
  `godot/scripts/components/pack_shop.gd`, dlc smoke,
  `docs/DLC_SERVER.md` §4.3/§7.4/§9/§11.
### BL-47: Four more animated crayon boxes, on a style-level mask decode — `done`
Logged 2026-08-08. BL-38 shipped two animated boxes and, without meaning to, a
ceiling: the effect mask hard-coded exactly two animation families, one per
colour channel, and a fifth idea had nowhere to live. Done 2026-08-08 —
**Embers**, **Ocean glass**, **Aurora** and **Firefly dust**, and the one
architectural change that made room for them.

- **THE EXTENSION: the mask's red and green are STYLE LEVELS, not amounts.** Red
  now names a member of the FIELD family (a page-space light washing over the
  wax), green a member of the SPECK family (points of light on a page-space cell
  grid). Red: `0.15` embers, `0.35` soft white sheen, `0.55` ocean caustics,
  `0.80` aurora, `1.00` full white sheen. Green: `0.5` firefly drift, `1.0` wink
  in place. Blue is still the per-stroke phase. Two channels, six boxes.
- **Why the level survives the blend, exactly — and it is exact, not close.** The
  mask is stamped with ordinary alpha blending, so a texel holds
  `payload * coverage` in rgb and `coverage` in alpha; `paint_display.gdshader`
  reads mask.a for nothing else, and that spare channel is the whole trick.
  First stamp on a transparent target is `payload * a` over `a`; a second stamp
  of the same payload is `payload * (a + a'(1-a))` over `(a + a'(1-a))`. The
  ratio is the authored level at any coverage, however many of the ~8
  overlapping dabs are down — which matters most at the feathered dab edge,
  where the raw channel is nearly nothing and the ratio is all there is. The
  decode rounds it to the NEAREST level.
  - **The one place it can misfire is the seam, and the seam is free because it
    is THIN — not because it is dim.** Where strokes of two different styles
    overlap-blend, the normalised value lands between two levels and
    nearest-level picks one of them. ~~Those texels carry a coverage-weighted
    amount of nearly zero~~ — **corrected by the BL-47 review**, which measured
    it: an embers stroke lapping over shimmer wax mis-decodes a band **5 px
    wide carrying up to 90% of a level**. Bright, and over in five pixels,
    because a stroke's edge is eight overlapping dabs deep and crosses the whole
    ladder of wrong levels at once. `paint_smoke` check 11c now pins that width,
    since a fifth field level or a softer brush would widen it quietly.
  - **The erase comes out cleaner than the seam**, and it was worth measuring
    separately: classic wax saturates as fast as it rubs out, so an animated
    area that was coloured in first goes OUT rather than changing style on the
    way — the brightest texel left at a wrong level is 2/255. (Rub a *single*
    animated stroke out with a single classic stroke of the same brush and the
    two profiles cancel to a residual bounded by 0.25 instead. Still fading, not
    switching.)
  - **Proved with pixels, not with algebra.** `paint_smoke` check 11b stamps a
    real stroke of each new family, runs it up to a real region boundary, reads
    the mask back off the GPU and asserts that *every* covered texel decodes to
    the authored level — 9381 of them per finish, zero wrong. It also prints the
    raw bytes, so a render target that ever started converting colour spaces
    would announce itself there rather than as a mystery.
- **The two levels BL-38 shipped did not move.** `1.00` and `0.35` in red, `1.00`
  in green are the numbers already sitting in every `page_NN_fx.png` on a
  player's disk. A saved page decodes to the look it was saved with, and the
  smoke asserts those three levels stay in the tables so a future round cannot
  quietly repaint saved work.
- **The boxes**, each with a baked base in `brush.gdshader` (so the frozen page
  and the saved PNG read right) and an animation style in the display shader:
  - **Embers** `&"embers"`, sheen level 0.15. Base: a cooled CRUST — the grain
    box's tooth with much deeper grooves (0.55× the crayon's colour against
    grain's 0.70×) and a faint warm lift on the ridges. Animation: a coarse
    page-space noise field read at a slowly ORBITING offset on a 7 s cycle,
    tinted `vec3(1.0, 0.55, 0.25)` — patches breathe, like coals being blown on.
    The orbit is deliberate: a linear drift walks off into fresh noise forever
    and reads as texture sliding past, not as breathing. **The subtlest box in the
    game** — measured at a peak frame-to-frame delta of 25/255 against shimmer's
    88 and twinkle's 150.
  - **Ocean glass** `&"ocean"`, 0.55. Base: `silk_grain` at low contrast with a
    cool lift toward white — wet glass. Animation: two noise fields at different
    scales drifting different ways, MULTIPLIED and then sharpened with a `pow`.
    The product is what makes it move like water instead of like two clouds.
  - **Aurora** `&"aurora"`, 0.80. Base: shimmer's satin, one notch gentler, on
    purpose — the curtain is meant to be the difference, so a frozen aurora page
    should read as quiet polished wax waiting for it. Animation: shimmer's
    travelling band ~3.5× wider and ~3.4× slower, and it HUE-SHIFTS the wax
    (`hue_shift()` ported from `brush.gdshader`) instead of washing it white,
    with only a whisper of added brightness. GLOBAL in page space like shimmer's
    band, for shimmer's reason: two aurora strokes that touch show ONE curtain.
    - **Gotcha, and it shipped wrong once.** The swing was damped by the
      curtain's Gaussian envelope *and* mixed by the same envelope — squaring it
      — which turned an intended ~20° rotation into a measured ~5°. The envelope
      is the mix WEIGHT; the angle is `sin(1.6u) * swing` and nothing else. Peak
      effective rotation is `sin(1.6u)·exp(-u²/2)` = 0.71 at u ≈ 0.72, times the
      swing times the level: ~0.35 rad, measured on screen as a 223°→238° hue
      sweep as the curtain passes.
  - **Firefly dust** `&"firefly"`, spark level 0.5. Base: twinkle's flecked wax
    turned right down — softer tooth, 26 px grid against twinkle's 17, 38% of
    cells carrying a mote, smaller motes, a much weaker lift toward white. A
    frozen firefly page has to read as faint dust; if it read as glitter the box
    would be twinkle with a different animation instead of its own quieter idea.
    Animation: the speck WANDERS — per cell a drift rate and a phase (the cell's
    own plus the stroke's, out of mask.b), sin/cos wander, and each speck swells
    and fades as it goes. **Twinkle puts its wink exactly on its baked fleck; a
    wanderer must not** — it starts near the baked mote and drifts off it, so its
    home is the same hash pulled into the middle half of the cell. Only fragments
    inside a cell draw that cell's speck, so the middle-half home plus a 0.17
    wander is what keeps the speck's CENTRE in the cell that draws it (1.8 px
    clear of the boundary at worst). ~~And what keeps the speck inside it~~ —
    **the BL-47 review found that overclaimed**: the radius runs to 5.5 px, so
    the widest specks lose the outer few pixels of their skirt to a straight cut
    when their drift takes them to the edge. Twinkle's trade inherited (its
    full-cell jitter and 11 px arms clip harder), and the alternative is
    evaluating nine cells per fragment.
- **The ladder is loudness order, and the new boxes went INSIDE the animated tail
  rather than on the end**: classic → Neon glow → Textured wax → Glitter →
  **Embers → Ocean glass → Aurora** → Shimmer → **Firefly dust** → Twinkle. Ten
  boxes; `sort_order` 32/34/36 and 45 slot between the existing 30/40/50 with no
  renumbering. Twinkle is still the last word. The palette smoke's BL-38
  assertion — "the ladder ENDS with exactly two animated boxes" — became six, and
  its SHAPE did not move: the animated boxes are a contiguous tail, however many
  there are, which is the point of having written it that way.
- **What did NOT change, and this is the measure of the extension.** No GDScript
  outside `brush_finish.gd` and the two smokes; `PageView`, `PaintCanvas`,
  `ColoringPage`, the palette contract, the save format and the region clip are
  untouched, because the sheen/spark uniforms already carried arbitrary payloads
  and both passes already went through the same stamp shader. The four bakeable
  finishes are byte-identical: `classic=2161738159 glow=3362623779
  grain=1121124693 glitter=3754632733`, the same digests BL-38 recorded on the
  same dev box. Every BL-38 rule keeps its teeth — frozen (`t = 0`) is a valid
  still frame, every light contribution is multiplied by the wax's own alpha
  (including the aurora's rotation, or a transparent texel would get a curtain on
  it), nothing per-frame on the CPU, and `effect_enabled = false` is still one
  fetch and one multiply.
- **Crayon previews** cost four `match` arms and no new drawing code, from the
  same primitives in the same canonical space, so the landscape dock's quarter
  turn is free (BL-21's rule). Each shows the finish's SHAPE, never its motion —
  BL-16's lesson that a strip full of moving things reads as noise.
- **Smokes: paint 97 → 120 → 123 (the review's check 11c), palette 241 → 247**;
  flow 258, shell 158, mobile 141
  and dlc 131 unchanged and green. Paint gained check 11b (above) plus, per new
  finish, the authored level landing in the mask to the byte, the region clip
  holding, the baked base being a STILL image with the animation frozen, and
  classic wax rubbing the level off through the ordinary blend. Palette gained
  the six-box animated tail in loudness order, each new id being KNOWN rather
  than merely resolvable (`resolve()` turning a typo into classic wax would let a
  misspelled `.tres` ship as silent wax and pass every other check), each payload
  being a member of a level table, and the decode round-tripping it.
  - **The counts recorded in the skill were stale before this round** — measured
    on this tree at HEAD, palette was 241 (recorded 237), flow 258 (234), shell
    158 (151) and dlc 131 (116). Corrected in the skill along with this entry.
- **Adversarial review, same day.** No defect in the shipped animation, three
  fixes: (1) `BrushFinish._nearest_level` broke a tie DOWN (`<`) while the
  shader's `normalized < threshold` chain breaks it UP, so the two decoders
  disagreed on exactly the 0.25 / 0.45 / 0.675 / 0.90 / 0.75 boundaries the
  contract is written in terms of — the loop compares `<=` now; (2) the two
  justifications above, corrected to what the pixels say and pinned by check
  11c; (3) `is_animated()` still documented itself as "true for SHIMMER and
  TWINKLE" and `mask_payload()` as "red = travelling sheen", both falsified by
  this very entry. Cleared on inspection: the four bakeable bases and shimmer's
  and twinkle's are untouched (the new modes are `else if` arms after them), the
  frozen `t = 0` frame is finite for all four, `hue_shift` is byte-identical to
  `brush.gdshader`'s, the aurora's peak rotation is the 0.35 rad the comment
  claims, `sort_order` 32/34/36/45 collides with nothing and matches `LADDER`,
  the four `.tres` ids are all KNOWN, and the 8-bit quantisation of the decode
  only misfires below ~4/255 of coverage, where the light amount is nothing.
- **Gotcha: `PackedFloat32Array` cannot hold a level table you intend to compare
  for equality.** `0.35` goes in and `0.3499999940395355` comes out, so `.has()`
  finds nothing and `is_equal_approx` against a `Vector2` component fails the
  same way. The tables are `Array[float]` and the smoke's authored pairs are
  plain float arrays, for that reason and no other.
- **Gotcha (harness): six windowed smokes run back to back steal each other's
  focus**, and the two palette checks that synthesise real touch events at real
  screen coordinates went red once because of it. Green three runs in a row on
  its own. When a windowed smoke fails an INPUT check in a batch, re-run it alone
  before believing it.
- Affected: `scripts/components/brush_finish.gd`,
  `scenes/components/brush.gdshader`, `scenes/components/paint_display.gdshader`,
  `scripts/components/crayon_button.gd`,
  `resources/palettes/sets/{embers,ocean_glass,aurora,firefly_dust}.tres` (new),
  paint + palette smokes, coloring-mechanics skill.

### BL-51: The top four crayon boxes, turned up into spectacle — `done` (2026-08-08)
Playtest on BL-47, verbatim: *"The last 4 crayon sets we created missed the point.
We have solid crayon sets, then a few crayon sets with subtle visual effects; these
latest crayon sets need to have OUTSTANDING visual effects and not subtle."* The
ladder is meant to be three tiers — solid wax, then subtle effects, then spectacle —
and BL-47 built its four boxes into the middle one. Done 2026-08-08: the four
re-aimed at the top, the ladder re-sorted so the tiers are three contiguous runs,
and a measurement added so this class of miss cannot ship green again.

- **THE ROUND IS TUNING, NOT ARCHITECTURE, and that is the headline.** Not one byte
  of BL-47's encoding moved: same `MASK_FIELD_LEVELS` / `MASK_SPECK_LEVELS`, same
  decode thresholds, same seam behaviour, same save format, same recipe fields. A
  `page_NN_fx.png` already on a player's disk reopens as **the same style** and
  simply performs it louder. `PageView`, `PaintCanvas`, `ColoringPage`, the palette
  contract and the region clip are untouched again.
- **Shimmer and twinkle were deliberately left alone.** They ARE the subtle tier;
  turning them up too would have left the round with nothing to say.
- **The ladder is three tiers now**: classic → Neon glow → Textured wax → Glitter →
  **Shimmer → Twinkle** → **Embers → Ocean glass → Aurora → Firefly dust**.
  `sort_order` 60/62/64/66 (was 32/34/36/45, i.e. three of the four sat *below*
  shimmer). Firefly dust is the last word. The palette smoke's animated-tail
  assertion kept its SHAPE — a contiguous animated tail — and changed its order.
- **What each box became** (all in `paint_display.gdshader` unless noted):
  - **Embers** — live coals. Three octaves of page-space noise, each ROTATED off the
    others, read at an orbit of 2.4 noise cells per 2.6 s breath (BL-47: 0.85 cells
    per 7 s); a fast two-beat flicker phased per patch; cinders on a fine field
    scrolling upward and cut hard. The crust it glows through went darker in
    `brush.gdshader` (0.44x the crayon's colour, was 0.55x) — coals only read as
    glowing through something if the something is dark.
    - **The finding that cost the most iterations: you cannot make blue wax orange
      by ADDING light.** The first cut added warm light at a modest gain over a wide
      threshold, exactly as BL-38's styles do. On the smoke's blue crayon it came out
      pale mauve and read as nothing — the blue channel is already high, so a warm
      sum runs to white, not to fire. Embers now MIXES an incandescent colour into
      the wax where it is hot, the way the aurora mixes its rotation, and adds the
      white heat on top of that. It is the second style that overrides the crayon's
      own hue, and like the aurora it leaves the wax alone everywhere it is not: the
      cold crust between the coals is still the child's blue.
    - **Gotcha: thresholding value noise draws its lattice.** Cubic-interpolated
      value noise is C1 but not C2, and its second derivative jumps at every cell
      boundary. BL-47's styles used the field gently and nothing showed; embers
      thresholds it hard, and the creases came out as dead-straight axis-aligned
      seams one noise cell apart, right across the stroke. `value_noise` in the
      display shader is QUINTIC now, and every octave of embers and ocean is spun off
      the others. (`brush.gdshader` keeps the cubic — nothing thresholds it there,
      and changing it would repaint every saved page.)
  - **Ocean glass** — a caustic web instead of two clouds. Each field is RIDGED
    (`1 - |2n-1|`, which turns a smooth field's half-height contour into a thin
    bright thread), two of them multiply, a finer faster glint layer rides on top,
    and the whole thing drifts ~5x faster than BL-47's. The threads being thin is the
    licence for making them this bright: the calm glass between them keeps the
    crayon's colour.
  - **Aurora** — two curtains, not one; undulating rather than marching as a straight
    bar; striped with vertical rays; sweeping ~5x faster; hue swing 0.62 → 2.1 rad;
    and carrying its own vivid light (gain 0.10 → 1.30) instead of a whisper of
    white. The hue mix is CLAMPED now — a 2.1 rad rotation about the grey axis can
    push a saturated crayon's channel negative, and a negative channel is an artefact
    that returns as a halo the moment anything multiplies by it.
    - **The colour ramp took three measurements.** Green-to-violet in two stops puts a
      muddy mix of the pair exactly where the envelope is brightest, so the core came
      out grey and the green never reached the screen. Three stops with BLUE at one
      end cost 15% of the peak swing (156 → 133) and failed the tier floor, because
      blue is where a blue crayon already is. Shipped: crimson → green → violet, i.e.
      both ends far from ordinary wax, in opposite directions.
  - **Firefly dust** — a swarm of bright wandering points with wide warm halos, each
    a hard core inside a shallow halo so it reads as a light rather than a dot.
    **It is drawn from the 3x3 cell NEIGHBOURHOOD** — the cost BL-47 named and
    declined, and the reason its wander was pinned at 0.17 of a cell. Baked motes
    brightened and enlarged in `brush.gdshader` to match, and both grids moved 26 → 24
    px together.
    - **The 3x3 window BOUNDS the wander and the halo, and getting that wrong is a
      hard seam, not a soft one.** If a fly may stray `s` cells outside its own, the
      nearest fly the loop cannot see can come within `(2 - s) - 1` cells of the
      fragment, and any halo reaching past that is chopped along a straight cell
      boundary at full brightness. A first pass at wander 0.62 put a fly it could not
      see 13.8 px away with a halo reaching 30. Shipped: the centre stays inside its
      own cell (0.02..0.98), the nearest unseen fly is 24.5 px off and the halo dies
      at 24.6. Coverage is bought with DENSITY and brightness, which that bound does
      not constrain.
- **THE MEASUREMENT — `paint_smoke` check 11d, and it is the durable half of this
  entry.** BL-47 shipped four boxes into the wrong tier with 123/123 checks green,
  because every check measured CORRECTNESS and none measured LOUDNESS. Check 11d
  profiles each animated finish on the composited screen over 3–4 s, on a patch of
  wax the size a child actually colours, and reports two numbers: **peak swing** (the
  biggest brightness change any sampled pixel goes through — "would you see it
  happen") and **coverage** (what fraction of the wax swings ≥64/255 — "does it
  happen over the drawing, or in one corner"). The four are held to a swing floor of
  120/255, to out-swinging shimmer by 1.4x, and to 45% coverage. Shimmer and twinkle
  are profiled and printed but held to nothing; being quieter is their job.
  - Shipped numbers: shimmer 97/99.5%, twinkle 138/6.9%, **embers 191/98.4%, ocean
    171/99.7%, aurora 160/99.5%, firefly 226/64.5%**.
  - **Coverage had to be a RATIO and the threshold had to be high.** The first cut
    counted pixels moving by 24/255 and every field style — shimmer included — pinned
    at 100% of the patch. A floor the subtle tier clears measures nothing.
  - **`-- --fx-shots <dir>`** dumps cropped, 3x-upscaled frames of each finish.
    Numbers say a finish moves; frames are how a human decides whether it moves WELL,
    and every design finding above came out of looking at them.
- **Gotcha (harness): a frame-spaced profile is not a time-spaced one.** Spacing
  captures by frame count is 3 s only while the window is v-sync limited. Run as a
  child of `flow_smoke` the window is occluded, v-sync limits nothing, 180 frames go
  by in well under a second, and the aurora — the slowest style — measured 76/255
  instead of 157 and failed. It passed standalone and failed nested, which is the
  worst shape a flake can have. Shader `TIME` runs on the wall clock, so the profile
  does too (`Time.get_ticks_msec()`).
- **`flow_smoke` now forwards a child smoke's FAIL lines.** Finding the above meant
  reproducing a run that only fails when it is not the focused window; "exited 1" was
  not enough to go on, and never will be.
- **The one thing not verified on hardware: the firefly loop's cost on a phone.** It
  is 9 cell evaluations per fragment, ~4 hashes each after the `present` reject, and
  it runs ONLY on texels the mask says are firefly wax — the other nine boxes,
  including the other three spectacle ones, are untouched. Desktop Vulkan shows
  nothing. If a low-end phone ever struggles, the lever is `firefly_cell` (fewer,
  bigger cells) or dropping to a 2x2 window with the wander bound tightened to match
  — never a 5x5, which is 25 cells for a halo that already dies inside the 3x3.
- **Smokes: paint 123 → 135**; palette 247, flow 258, dlc 131 unchanged and green.
  Shell and mobile are 199 and 156 — BL-48's numbers, which the skill still recorded
  as 158 and 141; corrected there with this entry.
- Affected: `scenes/components/paint_display.gdshader`,
  `scenes/components/brush.gdshader`, `scripts/components/brush_finish.gd`,
  `resources/palettes/sets/{embers,ocean_glass,aurora,firefly_dust}.tres`,
  `scripts/dev/paint_smoke.gd`, `scripts/dev/palette_smoke.gd`,
  `scripts/dev/flow_smoke.gd`, coloring-mechanics skill.

### BL-48: The overlay layer, sized for a phone — `done` (2026-08-08)
Playtest on an iPhone in portrait (web build): "the buttons and login forms, etc.
on mobile are difficult to see and work with". The gameplay layer had its mobile
pass (M6 / BL-21 / BL-33); the overlay layer never did. `canvas_items` + `expand`
means the logical canvas never narrows below 1152, so on a ~390 pt screen every
overlay was drawn at **a third** of its authored size: the settings panel floated
at 52 % of the width with 22 px type, and the account email clipped to
"Binaryrabbit101@gmail.c…" beside a 150 px Manage button.
- **One mechanism, three numbers** — `OverlayMetrics`
  (`scripts/components/overlay_metrics.gd`, a `Node` that parents itself to the
  overlay and dies with it). `squeeze` = logical canvas px per POINT, *measured*
  (`viewport.x / (window.x / screen_get_scale())`) and clamped to ≥ 1;
  `content_scale` = `min(squeeze, 2.4)`; `min_touch_px` = `44 pt × squeeze`,
  floored at DESIGN.md's 48. **Desktop is unchanged by construction**: a desktop
  window is bigger than the 1152 px base, so its squeeze clamps to exactly 1.0 and
  every authored number comes back byte-identical — there is no "desktop" branch
  anywhere.
- **Content stops growing; fingers do not.** The cap exists because the panel's
  inside is ~940 px and the widest unwrappable string in the layer ("Sync pictures
  too (uses more data)", on a `CheckBox`, which cannot wrap) is ~790 px of it at
  2.4×. The touch floor deliberately uses the **uncapped** squeeze, or a 48 px
  control would land at 42 pt on a 2.95× phone.
- **Shape decides width, the squeeze decides everything inside it.** In portrait a
  panel takes 94 % of the canvas (not 100 — the scrim is how every one of these is
  dismissed); in landscape it keeps its authored width. Aspect, never a pixel
  width (§3.5).
- **New convention with teeth**: a plain `BoxContainer` in an overlay is *a row
  that stacks in portrait*; an `HBoxContainer` is a row that never does (the two
  shop tabs). Five rows were retyped for it — settings' palette/account/confirm
  rows, the gate's Continue/Back, the Start-over pair, and the pack row built in
  code. It has to be a plain `BoxContainer` because Godot refuses `set_vertical()`
  on `H/VBoxContainer` — the same trap BL-21 hit with the palette body.
- **Baselines live in node metadata**, captured lazily the first time a control is
  walked, so `apply()` is idempotent, nothing has to remember what anything was
  authored at, and the pack shop — the one overlay whose rows are *built* — only
  has to call `apply()` again after `set_packs()`.
- **The email**: `AUTOWRAP_ARBITRARY` in portrait, not word wrap. An address has no
  spaces, so word wrapping leaves one line whose minimum width is the whole
  address — at 2.4× that is wider than the panel, and the label would push the
  panel off the screen instead of clipping. Breaking mid-address is ugly and shows
  every character; showing every character was the requirement.
- Gotchas: a `ScrollBar` is a `Range` and would have taken the 130 px touch floor
  down the side of the pack shop (they are internal children so the walk never
  reaches them — the guard is belt to that pair of braces); and
  `OverlayMetrics.attach()` applies as it enters the tree, i.e. *before* the caller
  can connect `applied`, so the two panels that reflow their own content ask again.
- **Residual, honest**: (1) the squeeze reads `screen_get_scale()` for the
  device-pixel ratio, which Godot implements on Web/iOS/Android/macOS and returns
  1.0 for elsewhere — correct for every platform this ships to, and clamped to 4×
  so a bad reading cannot explode the layout; a dev hook,
  `OverlayMetrics.debug_squeeze`, forces a phone's 2.95× on a desktop box (the same
  pattern `SafeArea.debug_insets` is). (2) **Nothing here can move the mobile-web
  virtual keyboard**: Godot's web `LineEdit` does not scroll the focused field
  above the on-screen keyboard, so on a short phone the password field can still be
  covered while typing. What BL-48 fixes is that the field is now 44 pt tall and
  full-panel-width instead of 19 pt — engine-level scroll-into-view is not
  reachable from GDScript. (3) The panels are not scrollable: if a future overlay
  grows past the canvas height in portrait it will overflow rather than scroll.
- Smokes: **shell 158 → 199** (check i — desktop unchanged first, then a real
  720×1280 window with a phone's squeeze forced on, across all five overlays: panel
  width fraction, the 44 pt floor measured back into points, the stacked rows, the
  email wrapping with room to draw every pixel of itself, a row built in code
  scaled too, and the desktop restored afterwards) and **mobile 141 → 156** (the
  same shape at the squeeze a 720×1280 window really produces — no override — plus
  the Start-over confirm and the landscape "back to 1.0" assertion). paint 97, flow
  258, dlc 131 unchanged. `palette_smoke` is 239/241 standalone on this branch and
  241/241 when `flow_smoke` runs it as a child process — **pre-existing**, verified
  identical on the tree before this change, and it is the known windowed-focus
  flake ("a press on a docked crayon still raises it").
- Affected: `overlay_metrics.gd` (new), `settings_panel.{tscn,gd}`,
  `adult_gate.{tscn,gd}`, `account_panel.{tscn,gd}`, `pack_shop.{tscn,gd}`,
  `coloring_page.{tscn,gd}` (Start-over confirm only), `main.gd` (gear + More
  books), `shell_smoke.gd`, `mobile_smoke.gd`, DESIGN.md §3.5.

### BL-49: The shelf is a rail you swipe, not a grid — `done` (2026-08-08)
Playtest, straight after BL-48: "the buttons on mobile on the book selection page
are covering up some of the coloring book selections. We believe it'll look nicer
to have books be laid out in a horizontal carousel instead." Both halves are the
same fact — BL-48 grew the two shell buttons to ~460 × 173 canvas px on a phone,
and the shelf's grid filled from the top left (BL-43) into exactly that corner.
A grid cannot dodge them; its job is to use the whole width. A rail can.
- **One row, and the grid stayed.** `Shelf` is still a `GridContainer` — it just
  gets a column per book now (`columns = cells.size()`), so **`ShelfBoards` and
  `ShelfBackdrop` are untouched**: the boards still group cells by y and draw one
  plank per row, and there is one row, so they draw one long shelf. Not one line
  of the BL-28 furniture changed for this.
- **The rail is one SCALED Control** (`BookCarousel`, `scripts/components/`,
  attached to a node in `book_select.tscn` — the same shape `ShelfBoards` has, no
  new scene file). `Track` carries a uniform `scale` and everything comes along:
  books, planks, contact shadows, lettering. Scaling the node rather than
  re-authoring sizes is why the spine, the page lip and the title stay in
  proportion — `BookCell` goes on drawing in the space its constants were written
  for. The scale is
  `clamp(min(OverlayMetrics.content_scale, (band height − headroom) / bookcase
  height), 0.55, 2.4)`: **1.0 on a desktop by construction** (BL-48's squeeze
  clamps there), 2.4× on a real phone — where a book is 538 canvas px, ~47 % of
  the glass, and about two are on screen with the next one peeking. The second
  half of the `min` is what stops a phone's LANDSCAPE canvas, which is SHORT,
  asking for a book taller than the band it is clipped to.
- **The shelf still knows nothing about the buttons.** `Main` measures its own two
  overlays and calls `BookSelect.set_chrome_band(bottom, free_width)` — told, never
  discovered, the way the shelf is told its books. `free_width` is **twice the
  smaller of the two gaps**, because the sign is centred on the canvas and the two
  buttons are nowhere near the same width: the 190 px pill decides it every time.
  With nobody telling it (every harness that drives `book_select.tscn` alone) the
  band is zero and the layout is the desktop one.
- **The sign gets out of the way in the one direction that has room.** "Pick a
  book" grows with the squeeze but only as far as it still fits BETWEEN the two
  buttons; when even its authored width will not (a portrait phone, where "More
  books" alone is 40 % of the canvas) it drops BELOW the band and takes the full
  squeeze instead. Measured at 2.95×: sign at y 268, buttons ending at y 221.
- **A swipe must never open a book, and that is defended twice.** The rail reads
  `ScreenTouch`/`ScreenDrag` in `_input` (which runs BEFORE the GUI phase, so it can
  watch a press a `BookCell` is also watching) and only claims the gesture past
  `DRAG_SLOP` = 14 px. On claiming it, (1) every cell is told to `cancel_press()` —
  toggling `disabled` is what actually drops `BaseButton`'s pending press — and
  (2) `consumed_gesture()` stays true until the NEXT press, so `BookSelect` ignores
  a `pressed` that arrives anyway. Two guards because the order in which a real
  mouse release and the touch event emulated from it arrive is the engine's
  business, not ours. A tap under the slop is untouched: the book owns it, exactly
  as before.
- **Momentum and snapping are the same gesture**: on release the flick is coasted
  forward on paper (`velocity × 0.20 s`), and the rail tweens to whichever book is
  nearest where it WOULD have stopped. A hard flick therefore skips books and a
  gentle one moves by one, with no separate "fling" mode. Books snap to the LEFT of
  the band, not to its centre — that is BL-43's rule surviving the rewrite, and it
  is also why the rail is **never centred when the shelf fits**: a two-book shelf
  and a twenty-book shelf must put the first book in the same place.
- **Gotcha: the mouse wheel cannot be read in `_gui_input` here.** A `BookCell` is
  `MOUSE_FILTER_STOP`, and Godot ENDS the GUI walk at a STOP control whether or not
  it accepted the event — so a wheel notch over a book never reaches the rail's
  `_gui_input` at all. It is read in `_input` with a rect test instead, which is one
  code path for finger, mouse-drag and wheel.
- **Gotcha: a book's `size` is no longer where it is drawn.** The rail is scaled, so
  `Control.get_global_rect()` under-reports a book by up to 2.4×. Anything comparing
  a book to something outside the rail (the harnesses' "is this book under a
  button") must ask `BookCarousel.get_cell_rect()`.
- **Desktop moved a little, and deliberately.** Books are one row instead of a wrapped
  grid, and they sit ~90 px lower (the band is centred vertically under a header row
  that now reserves the shell's 112 px strip). Every authored SIZE is unchanged —
  `flow_smoke` pins the desktop book scale at exactly 1.00.
- Smokes: **flow 258 → 268**, **shell 199 → 204**, **mobile 156 → 167**; paint 123,
  palette 247, dlc 131 unchanged and green. flow gained the one-row assertion, the
  desktop scale, and — pushed straight into the viewport with `push_input`, so it
  needs no window focus and cannot flake — a real drag across a book that scrolls
  the rail, is refused as an open, leaves the book tappable, and is followed by a
  tap that DOES open it. shell gained the phone-squeeze half (no book and no sign
  under either button at 2.95×, books at the 2.4 cap). mobile gained both
  orientations at the squeeze a real window produces, including a **new 812 × 375
  phone-landscape window** — the short canvas, where the book scale is height-bound
  rather than squeeze-bound and a book could be clipped by the band.
- Affected: `scripts/components/book_carousel.gd` (new),
  `scenes/screens/book_select.tscn`, `scripts/screens/book_select.gd`,
  `scripts/components/book_cell.gd` (`cancel_press`), `scripts/main.gd`
  (`_apply_shelf_chrome`), flow + shell + mobile smokes, DESIGN.md §2.
### BL-50: A page saved on one device never appeared on the other — `done` (2026-08-08)
> **Moot since BL-53 (2026-08-09).** A page saved on one device never appears on
> the other now *by design* — there is no sync. `SyncQueue` and its pull are
> gone; of the fix below only `GameState.page_paint_installed` and
> `ColoringPage`'s persist guards survive, and nothing emits the signal any
> more. Kept for the lesson, which outlived the feature: **a screen that reads
> a file once at load and never again will happily overwrite whatever lands
> underneath it.**

Playtest report: *"I'm logged in and saved my page canvas, yet when I logged in on
another device, I didn't see my previously saved page. Both apps were continuously
running without a refresh/restart."*

**The picture was never missing. It was on the second device's disk, underneath a
blank canvas.** The pull works and always did: signing in drains and pulls
progress, opening a book pulls that book's paint, `install_page_paint` writes the
PNG. What nothing did was tell the screen. `ColoringPage._apply_current_page()`
reads the paint layer off disk once, at page load, some hundreds of milliseconds
before the download lands — and then never looks again. So the child sat in front
of blank paper with the drawing already in `user://paint/`.

**And it got worse from there.** `_has_nothing_to_persist()` is "untouched AND no
file"; the pulled file makes the second half false, so the next save point read the
blank canvas back, wrote it over the picture and uploaded it — stamped *now*, which
wins last-write-wins. The bug did not just fail to show device A's drawing on
device B; leaving the page **destroyed it on the server**, and device A then pulled
the blank over its own copy. Nobody hit that in the report because they never left
the page, but it was one Back press away.

Three parts, none of them a new sync concept:

1. **`GameState.page_paint_installed`** — a second signal, emitted by
   `install_page_paint` and by nothing else. `page_paint_written` means "a file
   this device caused"; the new one means "a picture you did not draw is now on
   disk", which is the only case a screen has anything to do about.
   `SyncQueue` ignores it: it is the thing that wrote the file.
2. **`ColoringPage` adopts it** (`_on_page_paint_installed` → `reload_saved_paint`)
   when it is the open page and the visit has nothing of its own to lose — no
   unsaved strokes, no stroke down, no replay, no restore, no flip. The canvas is
   **cleared and rebuilt**, never composited over: the layer on screen and the file
   are two pictures of the same page, not an update of one another, so drawing the
   new over the old would leave the old showing wherever the new is transparent.
   A page that arrives finished sets `_pre_completed` through the existing
   `_restoring` branch, so it does not celebrate somebody else's colouring.
   If the child *is* drawing, the screen keeps the canvas and wins the next
   last-write-wins round with it — 8.2's "no response ever yanks a screen" is the
   rule, and refusing is what keeps it true.
3. **The persist guards** — `_persist_page` refuses while a restore is in flight and
   `_persist_page_async` waits it out (`_await_restore`, the twin of
   `_await_replay`). That closes the Back-pressed-mid-download window that was the
   data-loss half.

Plus the two the report's "both apps running" shape needs:

- **`SyncQueue._wants_server_paint` no longer refuses the open page outright.** The
  resume page **is** the open page by construction — `start_book` sets the cursor
  *before* it emits `book_started`, which is what runs the pull — so the blanket
  refusal meant a device that had already synced a page could never receive a newer
  copy of the one page a child looks at first, on any device, ever. It now refuses
  only when the two digests disagree, i.e. when this device holds pixels the server
  has not got. A copy the server has acknowledged is safe to replace, and part 2
  puts it on screen. (Only the *no local file* branch used to get through, which is
  why check (i) passed while the bug was live.)
- **`SyncQueue.on_signed_in` pulls the open book's paint** after its drain. The app
  on this device has been running the whole time; "pulled on book open" already
  fired for the book the player is in, back when there was no account to pull for.

**Not changed, deliberately.** The resume *cursor* still refuses to move under an
open book (`set_saved_page_index`) — turning the page under a colouring child is
the same failure this entry is fixing in the other direction. And the shelf needs
no refresh signal: `BookCell` draws a cover and a page count, never progress.

**No server change, no migration.** The endpoints, the merge and the payloads are
untouched; every line of this is client-side.

- Verified against a local `php artisan serve --port=8123`:
  **flow 256 → 270/270** (new check 4d: the picture is adopted by the OPEN page
  with no restart, pixel for pixel; a page that arrives finished does not
  celebrate; the next save point writes the picture back rather than the blank
  paper it replaced; and a second picture arriving while the child is drawing is
  refused). **sync 131 → 135/135** (check (i) extended: device B saves a NEWER
  picture for the page device A has open, A's next book open pulls it, and it is
  not pushed straight back). paint 97, shell 158, mobile 141, dlc 131 — all
  unchanged and green. Not run: palette (touches nothing here; the known
  windowed-focus flake).
  The web build was NOT used to verify any of this — the claude-in-chrome
  extension hangs Godot's `HTTPRequest` in a driven browser (BL-32).
- Affected: `godot/autoload/game_state.gd`,
  `godot/scripts/screens/coloring_page.gd`,
  `godot/scripts/backend/sync_queue.gd`, `godot/scripts/dev/flow_smoke.gd`,
  `godot/scripts/dev/sync_smoke.gd`

## Completed — archived

Full entries with as-built notes live in [BACKLOG_ARCHIVE.md](BACKLOG_ARCHIVE.md):

- **BL-1** — Default canvas zoom is too tight
- **BL-2** — Color picker slide-to-select
- **BL-3** — Brush size slider bar
- **BL-4** — Real page-curl flip; no auto-flip on completion
- **BL-5** — Tighter completion thresholds
- **BL-6** — Auto-save + manual save button
- **BL-7** — Start-over button per page
- **BL-9** — Coyote book display/mask split (one page, optional mask)
- **BL-10** — Free play: no completion gates + the coloring lock
- **BL-11** — Transient on-page celebration; BookComplete screen removed
- **BL-12** — Optional mask rendered as a layer under the detail image
- **BL-13** — App-branded splash screen, web loading shell, generated app icon
- **BL-14** — Wider brush-size range on the slider
- **BL-15** — Pick preview bubble + always-visible selection states
- **BL-16** — Pick feedback round 2 (chip removed, bigger bubble, louder states)
- **BL-17** — Undo / redo (stroke-recipe replay)
- **BL-18** — Erasure survives cloud sync: a wipe is a stamped instant that wins
  the merge (shelf + per-page clocks, two DELETE routes, dashboard wipe)
- **BL-19** — Web DLC download stall fixed (browser fetch hides 302s; web follows, native reads)
- **BL-20** — Child/Adult split removed — one crayon palette
- **BL-21** — Landscape: crayons dock beside the canvas
- **BL-22** — Crayon intensity ladder (light→dark, derived)
- **BL-23** — Fun crayon sets (superseded by BL-35's finish boxes)
- **BL-24** — Web authoring: book/page CRUD + server-side mapping + one-button publish
- **BL-25** — All books served by the server; release builds ship none
- **BL-26** — Client-side delta pack updates (fetch only changed files, zip fallback)
- **BL-27** — Splash auto-advances to the shelf (animated beat, tap = skip)
- **BL-28** — Bookshelf makeover: playroom wall + planks; cells drawn as real books
- **BL-29** — Toolbar crayon styling + save/start-over/undo-redo feedback
- **BL-30** — Book-open/close transition; richer page-curl (arc, shading, settle)
- **BL-31** — Crayon wax-stroke download animation in the pack shop
- **BL-33** — Landscape column shows every crayon (dynamic sizing + ranks, no scroll)
- **BL-34** — Cycle-left / cycle-right bars at the strip's ends (+ box-name flash)
- **BL-35** — Crayon boxes round 2: same lineup, escalating bakeable finishes
  (glow / grain / glitter). Animated finishes are BL-38.
- **BL-36** — Sticker sets: the cycle ring keeps going past the last crayon box
- **BL-37** — Sticker packs served by the API server (the manifest learns a content kind)
- **BL-38** — Animated crayon finishes (Shimmer, Twinkle) — the effect-mask channel,
  a second SubViewport saved as a second PNG
- **BL-32** — Web HTTPRequest "hang on Edge 151" — resolved as environmental:
  real browsers are fine; the hang only exists under the claude-in-chrome
  automation extension
- **BL-39** — Admin authoring screens restructured (list + editor pages, confirm
  modals, modified/last-published columns)
- **BL-40** — Artist book covers (manifest `cover`; shelf grid + open/close
  animation wear it, page 1 stays the fallback)
- **BL-41** — Animated stickers (sprite-sheet PNG + manifest
  `anim {hframes, vframes, frames, fps}`; absence = still)
- **BL-42** — Stickers peel off the canvas (tap → badge → peel; first-class
  history entry, sync-safe)
- **BL-43** — Bookshelf grid fills from the top-left
- **BL-44** — Shop tabs: coloring books | sticker sets
- **BL-45** — Palette: cycle bar un-stacked from the intensity tile (bottom-row
  tool band was vertical)
- **BL-46** — Start over is a soap-wash shader (`PageWash`), not a flash
