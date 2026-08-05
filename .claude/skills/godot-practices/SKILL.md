---
name: godot-practices
description: Project conventions for ColoringBook, distilled from the official Godot best-practices docs. Use before creating any scene, script, resource, autoload, or folder — and when reviewing structure. Triggers — "where should this file go", "new scene/script/resource", "autoload or not", naming questions, or restructuring work.
---

# Godot conventions — ColoringBook

Distilled from the official docs ([Best practices](https://docs.godotengine.org/en/stable/tutorials/best_practices/index.html)), applied to this project. The Godot project root is `godot/`.

## Naming

- Files & folders: **snake_case** (`page_view.tscn`, `game_state.gd`). Never mixed case — the exported PCK filesystem is case-sensitive and mismatches break exports.
- Node names: **PascalCase** (`PageView`, `PaletteChild`) to match built-in node styling.
- GDScript: classes registered with `class_name` in **PascalCase** (`PageDef`); functions/variables snake_case; signals **past tense** (`page_completed`, `region_locked`, `color_picked`).

## Folder layout (fixed for this project)

```
godot/
  scenes/            # .tscn — screens/ for full screens, components/ for reusable pieces
  scripts/           # .gd — mirrors scenes/ structure
  resources/         # .tres data — books/, palettes/
  assets/            # art & generated data — books/<book>/page_XX.png, _idmap.png, _regions.json
  autoload/          # autoload singleton scripts only
  tools/             # dev-only headless scripts (mapping pipeline); never referenced by game scenes
  addons/            # third-party only
```

- Keep an asset next to the thing that uses it only when it's unique to it; shared art goes under `assets/`.
- `.gdignore` (empty file) in any folder Godot should not import/scan.

## Scene & script architecture

- **Scenes self-contained.** A scene must run without knowing its environment ("no dependencies if at all possible"). Anything external is **injected by the parent** — via exported properties, `NodePath`s, or method calls after instancing. Children never reach up or use absolute paths like `/root/...` (autoloads excepted).
- **Signals up, calls down.** Children emit signals; parents connect and respond. Parents call methods / set properties on children. Sibling scenes never talk directly — route through the common parent (`main.tscn`).
- **Autoloads only for truly global state.** This project has exactly one: `GameState` (mode, current book/page, save/load). Do not add autoloads for things a parent scene could own — think hard before adding a second.
- **Scenes vs scripts:** scenes for anything with a node tree / visual composition; plain `class_name` scripts (often extending `Resource`) for data and logic that needs no nodes — `BookDef`, `PageDef`, `PaletteDef` are Resources in `.tres` files, not nodes.
- **Not everything is a node.** Prefer `Resource` for data, `RefCounted` for pure logic helpers. Nodes are for things that live in the tree.
- Entry point is `main.tscn`: it swaps screen scenes and injects their dependencies. Think of the SceneTree relationally, not spatially.

## Data & persistence

- Authored game data → custom `Resource` (`.tres`) with `@export` vars, type-hinted.
- Player progress/settings → `user://` (JSON or `ConfigFile`), written by `GameState` only.
- Generated page data (`_idmap.png`, `_regions.json`) is **build input, never hand-edited** — regenerate via the pipeline (see the `mapping-pipeline` skill).

## Version control

- `.godot/` is ignored (already in `godot/.gitignore`); `*.import` files **are** committed.
- Import settings matter here: ID-map PNGs must keep their lossless import flags (see `coloring-mechanics`) — review `.import` diffs before committing.

## This project's platform baseline

- Mobile (touch) + PC (mouse) with **one input code path** (touch emulation from mouse).
- UI built with anchors/containers; touch targets ≥ 48 px; stretch mode `canvas_items`, aspect `expand`.
- After any change, run the game and check debug output before declaring done (see the `godot` skill).
