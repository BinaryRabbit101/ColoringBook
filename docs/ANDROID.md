# Android build — one-time setup

The Android export **preset is committed** (`godot/export_presets.cfg`, preset name `Android`) and
validated: Godot 4.5.1 loads it and reports no configuration errors other than the missing export
templates. Everything below is machine setup, not project work.

## Status on the M6 dev machine (2026-08-05)

| Prerequisite | State |
|---|---|
| Android SDK | **installed** — `C:\Users\binar\AppData\Local\Android\Sdk` (already in editor settings) |
| Java (JDK 17+) | **installed** — `C:\Program Files\Eclipse Adoptium\jdk-25.0.0.36-hotspot` |
| Debug keystore | **present** — `%APPDATA%\Godot\keystores\debug.keystore` (pass `android`) |
| Export templates **4.5.1.stable** | **MISSING** — only `4.4.1.stable` is installed |

So the only blocker is the export templates, and therefore **no APK was built for M6**. The exact
failure:

```
ERROR: Cannot export project with preset "Android" due to configuration errors:
No export template found at the expected path:
C:/Users/binar/AppData/Roaming/Godot/export_templates/4.5.1.stable/android_debug.apk
No export template found at the expected path:
C:/Users/binar/AppData/Roaming/Godot/export_templates/4.5.1.stable/android_release.apk
```

## The one-time setup

### 1. Install the 4.5.1 export templates (the only missing piece)

Either from the editor — **Editor → Manage Export Templates… → Download and Install** — or by hand:

1. Download `Godot_v4.5.1-stable_export_templates.tpz` from
   <https://github.com/godotengine/godot/releases/tag/4.5.1-stable>.
2. Unzip it and move the extracted `templates/` folder to
   `%APPDATA%\Godot\export_templates\4.5.1.stable\` (the folder must contain
   `android_debug.apk` and `android_release.apk` directly, not a nested `templates/`).

Verify: `dir "%APPDATA%\Godot\export_templates\4.5.1.stable\android_debug.apk"`.

### 2. Android SDK (already done here — for a fresh machine)

Install Android Studio, then in its SDK Manager add the **Android SDK Platform-Tools**,
**Build-Tools 34+** and a **platform** (API 34+). Point Godot at it:
**Editor → Editor Settings → Export → Android → Android SDK Path**.

### 3. Java (already done here — for a fresh machine)

Install a JDK 17 or newer (Temurin/Adoptium is fine) and set
**Editor Settings → Export → Android → Java SDK Path** to its install directory.

### 4. Debug keystore (already done here — for a fresh machine)

```
keytool -keyalg RSA -genkeypair -alias androiddebugkey -keypass android \
  -keystore debug.keystore -storepass android -dname "CN=Android Debug,O=Android,C=US" \
  -validity 9999 -deststoretype pkcs12
```

Then set **Editor Settings → Export → Android → Debug Keystore** to that file, with user
`androiddebugkey` and password `android`.

## Building

```
"<godot_exe>" --headless --path godot --export-debug "Android" "<out>/coloringbook_debug.apk"
```

Release builds use `--export-release` and need a real (non-debug) keystore configured in the
preset's `keystore/release*` options — deliberately left empty in the committed preset so no
signing material is ever checked in.

## What the preset says, and why

| Option | Value | Why |
|---|---|---|
| `package/unique_name` | `org.binaryrabbit.coloringbook` | stable application id |
| `package/name` | `Coloring Book` | launcher label |
| `version/code` / `version/name` | `1` / `0.6.0` | tracks `application/config/version` |
| `architectures` | `arm64-v8a` + `armeabi-v7a` | 64-bit is required by Play; 32-bit keeps older mid-range devices working |
| `gradle_build/use_gradle_build` | `false` | no plugins, no custom Android source — the prebuilt template is enough and keeps the build a single command |
| `screen/support_*` | all `true` | phones and tablets |
| `screen/immersive_mode` | `true` | the page is the app; system bars would steal touches near the palette |
| permissions | **none** | the game only writes `user://`; `custom_permissions` is empty and every named permission is left at its `false` default |
| `user_data_backup/allow` | `false` | progress is local and cheap to recreate |
| `launcher_icons/*` | empty | falls back to `application/config/icon` (`res://icon.svg`) — M6 deliberately ships no bespoke Android icon yet |
| `exclude_filter` | `assets/books/*/source/*` | the artist's full-resolution originals are dev files; they are `.gdignore`d for the editor and excluded from the package too |

Orientation is a **project** setting, not a preset one: `display/window/handheld/orientation=6`
(`SENSOR`) in `project.godot` allows portrait *and* landscape, which is what the M6 layout pass was
built for. Texture compression is likewise a project setting in Godot 4:
`rendering/textures/vram_compression/import_etc2_astc=true` gives ETC2/ASTC on Android. (The page ID
maps are exempt by design — they import with `compress/mode=0` and must stay lossless.)

## Renderer

The project ships the **Mobile** renderer (`rendering/renderer/rendering_method="mobile"`), which is
Vulkan. See `docs/DESIGN.md` §3.5 for the reasoning; the short version is that the Compatibility
(OpenGL) renderer exposes no `RenderingDevice`, so the asynchronous paint readback the coloring loop
depends on would silently fall back to the blocking one. A device with no Vulkan 1.0 driver would
need `gl_compatibility` and would take that stall — the code degrades rather than breaks.
