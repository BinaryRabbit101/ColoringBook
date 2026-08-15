---
name: godot
description: Build and test the ColoringBook Godot game via the godot-mcp server. Use whenever the task involves creating/editing Godot scenes or nodes, loading textures, running the game to test it, or reading Godot debug output. Triggers — "add a node", "create a scene", "run the game", "why is it crashing", or any work on .tscn/.gd files in this project.
---

# Godot MCP — ColoringBook

This project (Godot **4.5.1.stable**, lives in the `godot/` subfolder) has the **godot-mcp** server wired via [godot/.vscode/mcp.json](../../../godot/.vscode/mcp.json).
Use it for all scene/node manipulation and for running the game. It does **not** author
GDScript — write `.gd` files with the normal Write/Edit tools, then attach them via `edit_node`.

## Fixed values for this project

- **projectPath** (required by almost every tool): `c:\Users\binar\Documents\ColoringBook\godot`
- All scene/script/texture paths are **relative to the Godot project root** (e.g. `scenes/main.tscn`, not `res://...` and not prefixed with `godot/`).
- Godot exe is wired through `GODOT_PATH` in mcp.json; you don't pass it. Direct CLI runs (headless tool scripts) use:
  `C:\Users\binar\Documents\Godot\bin\Godot_v4.5.1-stable_win64.exe`
  (Moved here 2026-08-15: the old `OneDrive\Desktop\Godot\…` copy vanished — OneDrive is
  not a safe home for a 160 MB binary. Re-extract from
  `C:\Users\binar\Downloads\Godot_v4.5.1-stable_win64.exe.zip` if it goes missing again.)

## What the MCP can and cannot do

| Can do (use MCP tool)                                   | Cannot do (use other tools)                          |
|---------------------------------------------------------|------------------------------------------------------|
| Create scenes, add/edit/remove nodes, save scenes       | Write GDScript logic → use **Write/Edit** on `.gd`   |
| Load sprites onto Sprite2D, export MeshLibrary          | Edit project settings / input map → edit `project.godot` directly |
| Run/stop the game, read debug output                    | Connect signals in the editor UI → set in `.gd` `_ready()` or via `.tscn` |
| Launch the editor, query version/project info/UIDs      | Inspect a node's current properties → read the `.tscn` file |

## Standard workflows

### Create a new scene with nodes + a script
1. `create_scene` — set `scenePath` and `rootNodeType`.
2. `add_node` for each child. `parentNodePath` defaults to root; use it for nesting.
3. Write the `.gd` file with **Write** (under `scripts/`, mirroring the scene path).
4. Attach it: `edit_node` with `properties: { "script": "scripts/<name>.gd" }`.
5. `save_scene` (use `newPath` only to fork a variant).

### Test a change
1. `run_project` (optionally pass a specific `scene`). 2. `get_debug_output` to read prints/errors. 3. `stop_project` when done.
Prefer this over `launch_editor` for quick iteration — it captures output. Use `launch_editor` only when the user wants to work in the GUI.
**Always** check `get_debug_output` after running and report errors verbatim — never claim it works without confirming.

## Gotchas

- Godot **4.4+ uses UIDs**. After adding/moving files outside the editor, broken refs can appear — `update_project_uids` resaves resources to fix them; `get_uid` fetches a file's UID.
- Paths are project-relative, **not** `res://` — passing `res://...` will fail.
- A node's type can't be changed after creation; `remove_node` + `add_node` instead.
- `edit_node`'s `properties` maps to the node's exported/built-in props (e.g. `position`, `texture`, `script`); nested resources may need to be set in the `.gd` instead.
- SubViewports and shader materials (core to this game's painting stack) are easier to configure in `.tscn`/`.gd` than through `edit_node` — prefer authoring those directly in files.
