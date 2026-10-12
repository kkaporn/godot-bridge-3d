# godot-bridge-3d — patched godot-bridge (private fork)

This repository started as a **patched drop-in copy of [Smalldy/godot-bridge](https://github.com/Smalldy/godot-bridge) 0.2.0** (MIT, see `LICENSE`) and is now an independent fork at **0.4.2**.
The root of the repo **is** the installable plugin package: everything under `plugin/` and `client/` plus `package.json` /
`cordis.patch.yml` works exactly like the upstream plugin — it just carries the 3D gap-fill pack below.

The original 3D gap-fill pack was **+1491 / -5 lines across 3 files** (`plugin/mcp_interaction_server.gd`,
`plugin/godot_operations.gd`, `plugin/godot-bridge.mjs`) against upstream 0.2.0; those files have kept moving since.
Verified on **Godot 4.7.2**; the upstream contract check (`npm run check`) passes.

## What was added

**Runtime commands** (`godot_command`, needs a windowed instance for the render ones)

| command | what it does |
|---|---|
| `render_camera` | render a chosen `Camera3D` off-screen to PNG on disk or base64 (`camera_path` `width` `height` `output_path` `fov` `transparent_bg`). Headless has no rendering backend — this is why `godot_run_project` must be used. |
| `mesh_collision` | bake collision for a `MeshInstance3D`: `trimesh` / `convex` / `convex_multi` / `from_aabb` / `from_aabb_sphere` / `from_aabb_capsule`. Imported models should use the AABB/convex variants — trimesh on imported meshes is a known frame-rate trap and raycasts do not hit `ConcavePolygonShape3D`. |
| `csg_bake` | bake a CSG tree into a static mesh or StaticBody3D, optionally generating UV2 (`unwrap_uv2`) — the same pipeline the GigaBake editor plugin uses, but callable at runtime (`mode` `name` `reuse_existing` `keep_csg`/`delete_csg`). |
| `get_material_state` | read back what is *actually* rendering: `material_override` → surface override → mesh material → `get_active_material`, plus ShaderMaterial uniform values. |
| `unwrap_lightmap_uv2` | generate UV2 and set `gi_mode = STATIC` (the step before a lightmap bake). |
| `build_occluder` | build an `ArrayOccluder3D` from mesh surfaces — occlusion culling **without the editor**. |
| `lightmap_check` | read-only pre-flight for the editor bake button: per-mesh UV2/`gi_mode`, whether the LightmapGI is a direct child of the scene root, whether lights are `STATIC`, and a `ready_to_bake` verdict with blockers. |
| `compare_images` | visual regression between two renders (metrics + per-pixel max delta + optional diff image). |
| `environment` (extended) | +55 post-processing keys: `volumetric_fog_*`, `ssil_*`, `sdfgi_*`, advanced `fog_*`, advanced `glow_*`, `background_energy_multiplier`, plus a `non_default_extra` read-back. |
| `terrain` (extended) | new `action:"add_collision"` for the built-in heightmap terrain. |

**Headless operations** (`godot_headless_op`)

| op | what it does |
|---|---|
| `import_info` | read a `<asset>.import` sidecar: `remap` (uid/type/dest), `deps`, all importer `params`, plus a `.gdignore` check. |
| `instantiate_scene` | instantiate a `.glb`/`.tscn` into a `.tscn`, optionally replacing a placeholder and keeping its transform, with a node-count serialization gate (a broken owner chain silently drops nodes). |
| `list_subresources` | enumerate the sub-resources an imported asset exposes (`res://x.glb::ArrayMesh_xxxx`, materials, animations, skins). |
| `class_api` | dump any class's inheritance chain, methods (return type, argc, static), properties, signals, enums and integer constants from `ClassDB` — stop guessing engine API names. |
| `scan_dependencies` | walk a resource dependency graph: missing dependencies, cycles, `.import`/`.uid` sidecar consistency. |
| `audit_scene` | scene audit: owner chain, null meshes/shapes, pack/re-instantiate node-count gate, instanced sub-scene count. |

**Tool parameters**

- `godot_run_headless mode:"import"` → `--headless --path P --import` (imports pending assets, then quits).
- `godot_run_project` → `write_movie` + `fixed_fps` + `quit_after` (deterministic capture; must run windowed) and
  `ignore_error_breaks` (default on: without it, a runtime script error drops Godot into its interactive `debug>` prompt and the process never exits).

## Layout

```
plugin/, client/ ...   the patched, installable plugin package (repo root) — exactly one copy of every file
docs/                  the full gap report (zh-CN): gap list, priorities, landing approach, verification log
scripts/               upstream contract checker (npm run check)
```

## Install from GitHub

This repo is a normal DSH plugin package (`package.json` + `dsh.bundle.patch` + `plugin/` `client/`), so a DSH profile
can install it **straight from GitHub**. A profile pins plugins by spec in its own `package.json`; on this machine the
upstream one is currently pinned as `"godot-bridge": "github:Smalldy/godot-bridge"`. Point it at this fork instead:

```jsonc
// ~/.dsh/profiles/<profile>/package.json
"dependencies": {
  "godot-bridge": "github:kkaporn/godot-bridge-3d",
  // private repo over SSH instead (no token needed, uses your key):
  // "godot-bridge": "git+ssh://git@github.com/kkaporn/godot-bridge-3d.git"
}
```

Then install and restart:

```powershell
cd $env:USERPROFILE\.dsh\profiles\<profile>
pnpm install          # fetches the plugin from GitHub into node_modules
# restart DSH once so the plugin row reloads with the patched files
```

If your DSH build exposes the plugin CLI, the equivalent one-liner is
`dsh plugin --profile <profile> add github:kkaporn/godot-bridge-3d`.

**The repo is private**, so fetching it needs credentials: a token for the `github:` HTTPS spec, or your SSH key for
the `git+ssh:` spec. Importing over plain HTTPS also needs `github.com` reachable (a `hosts` entry that points
`github.com` at `127.0.0.1` silently breaks it; `git+ssh://` goes through `ssh.github.com:443` and is unaffected).

### Alternative: drop-in replace

Copy `plugin/` + `client/` + `package.json` + `cordis.patch.yml` over an installed `godot-bridge`, then **restart DSH
once** so the new command/op names are registered. `npm run check` and `npm test` verify the copy without needing Godot.

## Verification evidence

`docs/` has the report with the Godot 4.7.2 measurements (headless capture failure, `--import` behaviour, `.glb`
sub-resource naming, why the LightmapGI bake cannot be driven from script), and `CHANGELOG.md` records what each
version fixed and how it was found. The 0.2.0-era patch pack was removed on 2026-10-13 so that the repo holds exactly
one copy of every plugin file; it stays reachable in history at commit `d16bb94` (`git show d16bb94:patch/README.md`).

## Upstream credit

Fork/patched copy of **Smalldy/godot-bridge** (MIT). The three patched files remain MIT-licensed; the surrounding
package is upstream's work.
