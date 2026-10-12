# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.2] - 2026-10-12

### Fixed

- **`remove_node` could delete the scene-tree root and take the server with it.** `remove_node {node_path: "/root"}` answered `{"success": true, "removed": "root"}` and then the interaction server was gone — it is an autoload parented under `/root`, so it was freed along with everything else, and the client got `ECONNREFUSED`. Because the server is the only way to undo a mistake, the game had to be restarted by hand. `remove_node` and `reparent_node` now call a shared `_refuse_server_fatal` guard that refuses the scene-tree root, the server node itself, and any ancestor of the server. Only the node being moved is checked — reparenting a node *into* `/root` is the normal way to move it to the top level and must keep working.

  Found by fuzzing, not by hand: nobody hand-tests "delete the scene root", because nobody expects to. Normal-argument tests never reach the path at all.

### Added

- **`make-game/examples/interface_fuzz.gd`** — a reusable fuzz harness. Every command gets a set of malformed payloads (wrong types everywhere, missing fields, `null`, negative numbers, `../` paths, invalid code), and the pass condition is not "the command succeeded" but "the service still answers after every call". It distinguishes a slow call, a TCP hiccup and a genuinely dead service: liveness is probed with a retry and a delay, because a single failed probe among a thousand rapid connections produces false positives — an earlier version of this same harness reported 103 phantom wedges that way. Verified: 116 commands × 10 payloads = 1160 calls, 0 wedges, service alive throughout.
- **`godot-gdscript` gains a "destructive commands need a guardrail" section.** The rule, the three targets to refuse (scene-tree root, the manager itself, any ancestor of it), the `_refuse_server_fatal` implementation, and the method for finding the risky call sites — grep `.queue_free()` / `.free()` / `.reparent(` / `remove_child(` and ask, for each, whether the node came from user input.
- **`godot-gdscript` documents error-path fuzzing** next to the smoke harness: minimal-valid-argument testing only covers the happy path, and the happy path is not where an agent breaks things.

### Changed

- **`godot-gdscript` "three silent failures" now carries the full count of defects these harnesses found** — four, not two: a wedged server, a deleted scene root, a misleading error string, and an ignored timeout.

## [0.4.1] - 2026-10-12

### Fixed

- **One bad parameter could permanently wedge the interaction server.** `_handle_command` cleared `_busy` only when a handler replied or when the client disconnected. A handler that aborted part-way through a GDScript runtime error never reached its `_send_response`, so `_busy` stayed true and *every* later command was refused with `Server busy` until the game was restarted. `procedural_mesh` hit this on a mistyped argument shape. Dispatch now sets a `_responded` sentinel before the match and, if the handler died without replying, answers with an explicit error and frees the slot. Verified by injecting a command that aborts mid-handler: the server returns `Command '_boom' aborted on a script error … The server stayed responsive.` and keeps serving.
- **`procedural_mesh` accepts both vector shapes.** It read `v[0]`/`v[1]`/`v[2]`, so `{"x":…,"y":…,"z":…}` — the shape other commands in the same plugin use — raised `Invalid index` and triggered the wedge above. New `_to_vec3`/`_to_vec2` helpers take either an array or a dictionary; `procedural_mesh` uses them for vertices, normals and UVs.
- **`http_request` ignored the caller's timeout and reported failures as successes.** It awaited `request_completed` bare, so an unreachable host held `_busy` for the whole 30 s default with no way to shorten it, and the response was always `{"success": true, …}` even when the request had failed. It now races the signal against a timer, returns `success: false` with the `HTTPClient` result code on failure, and a real 200 was confirmed against a local listener (body and status correct).
- **`spawn_node` said `Failed to instantiate` for abstract classes.** `ClassDB.class_exists()` is true for `CSGShape3D`, `Shape3D`, `BaseButton` and friends but `instantiate()` returns null. The error now says the class is abstract and lists its concrete children (`Try one of: CSGMesh3D, CSGSphere3D, CSGBox3D, …`).

### Added

- **`godot-gdscript` gains a "three silent failures" section.** GDScript does not throw: a runtime error prints, aborts the current function and returns null. Three consequences, all hit in practice — statements after the error never run; a skipped cleanup call wedges whatever it was holding (the `_responded` sentinel pattern is now documented); and failed type conversions quietly yield defaults (`float("abc") == 0.0`, `Vector3` from a string is zero) so "it didn't error" never implies "the value is right".
- **`godot-gdscript` gains a parameter-shape rule and an abstract-class table.** Vector arguments arrive as either `[1,2,3]` or `{"x":1,…}` depending on the caller; one shared `_to_vec3` beats repeating `v[0]` at every call site.
- **`make-game/examples/service_smoke.gd`** — a reusable whole-interface smoke harness. It sends one minimal call per target and sorts results into PASS / PARAM (caller gave a wrong target or argument) / BUG (the target itself failed or hung), probe-checking liveness after every failure so a single dead service does not read as dozens of independent defects. Confirmed on 116 interaction-server commands plus 38 more with purpose-built node fixtures: 153 calls, 0 defects.
- **`make-game/examples/classify_check.gd`** — a self-check proving that harness's verdicts are not vacuous. A smoke script that is always green is not testing anything; this one asserts the classifier returns PARAM for a wrong target and PASS for a live probe.
- **`godot-gdscript` documents the smoke-harness method** alongside "compute first, look second": hand-testing dozens of commands is as unreliable as reading numbers off a screenshot, and it mislabels a slow command as a dead one. Two mandatory details are recorded — the socket timeout must exceed the command's own timeout, and a dead service must be distinguished from a single bad command.

### Changed

- **`scripts/install-skills.test.mjs` reports real bytes.** It printed `String.prototype.length` while claiming bytes; the skills are mostly CJK, where one UTF-16 code unit is three UTF-8 bytes, so the numbers were ~45% low and looked like a truncated install.

## [0.4.0] - 2026-10-12

### Added

- **"Compute first, look second" promoted to a hard rule in all three skills.** The same mistake kept recurring in 3D — judging whether a *number* was right by looking at a screenshot. A terrain prototype spent three rounds tuning parameters by feel before the fourth revealed a plain aspect-ratio problem (96 units wide, only 29 of relief). The rule is now explicit: anything expressible as a number becomes an assertion run through `godot_run_headless --script` before a screenshot is taken; screenshots confirm, they never verify. Stylistic preference is not mathematics — it must not be dressed up as an assertion, and "aesthetics" must not be used as an excuse for a wrong value.
- **`godot-gdscript` gains a 3D spatial-mathematics section (rules 16–21).** Every item comes from a real procedural skeleton + skinning implementation, and every one was caught by an assertion rather than by eye:
  - Query a class with `class_api` instead of recalling its methods (the parameter is `class_name`, not `class`).
  - **`Skeleton3D` has no bind API** — binds live on the `Skin` resource; guessing otherwise yields `Invalid call. Nonexistent function 'get_bind_pose'`.
  - **In Godot 4, rest and pose are independent quantities.** A fresh skeleton has an identity pose, not its rest pose. The renderer skins against pose, so setting only rest makes every vertex jump on the first frame — and `reset_bone_poses()` is a no-op when no pose was ever set.
  - **A bone's rest is a local transform in the parent's space**, not a world position; writing absolute positions makes Godot count every parent offset twice.
  - **Do not invert the bind twice in the LBS formula.** `get_bind_pose()` already contains the inverse; inverting again squares the offset. The bind itself must be built from the inverse of the *global* rest.
  - **`SurfaceTool` exposes no bone-weight API** (only `set_bones` in 4.7); weights go straight into `Mesh.ARRAY_BONES` / `ARRAY_WEIGHTS`, and zero-weight padding must be appended *after* sorting by weight.
- **`make-game` gains a "procedural assets" section**, answering "can you just generate trees / mountains / characters?": yes. Terrain via `FastNoiseLite` with domain warping, voxel worlds via `GridMap`, organic shapes via `procedural_mesh` (accepts arbitrary vertex arrays — no shape restriction), assemblies via `CSG`. Character skeletons and skinning are equally computable: LBS is `v' = Σ wᵢ · Bᵢ · v`, with no part that resists calculation. Seven-step procedure plus four mandatory assertions.
- **`make-game/examples/` ships two verified runnable scripts** — `procedural_rig.gd` (20 bones, 1330 vertices, 2280 triangles) and `rig_check.gd` (8 assertions, all passing). The workflow in the skill is no longer advice; it ships with code that runs.
- **`godot-playtest` documents screenshot caching and formula-based camera checks.** `screenshot` can return a stale frame after a scene change or a restart while `get_scene_tree` already reports the new scene; the test is whether two consecutive calls return byte-identical base64, and the workaround is `eval` + `save_png`. Also documents the most common cause of a black 3D view — the camera facing away from its subject — with the angle formula, and why `look_at` / `look_at_from_position` beats a hand-written Euler triple.

## [0.3.0] - 2026-10-12

### Added

- **Bundled game-development skills.** The tools drive Godot; the skills teach the agent *what* to drive it with. `skills/` ships three Chinese-language skills that name these tools explicitly, so the agent follows a worked sequence instead of improvising one:
  - `make-game` — the "I want to make a game / how do I start" path: pin the core action, the lose condition and 2D-vs-3D, build the smallest playable slice, then add one layer at a time with a verification step per layer, then export.
  - `godot-gdscript` — the GDScript traps that cost the most time: `clamp()` returning `Variant` under `:=`, `BaseMaterial3D.new()` being a parse error that kills the whole script, `$` returning null outside `_ready()`, `%UniqueName` silently nulling when `unique_name_in_owner` is unset, `await` on a signal that never fires, and an eight-row runtime-error → real-cause table.
  - `godot-playtest` — the verify loop: start, press keys, screenshot, read logs. Includes the `key_hold` / `key_release` pairing (a forgotten release leaves a direction stuck on), the black-screen triage, and headless assert-script testing.
- **Skills are installed on plugin load.** `apply()` mirrors every `skills/<slug>/SKILL.md` into the DSH user-skill directory (`$DSH_HOME/skills`, default `~/.dsh/skills`) — the only place the host discovers them; a skill directory inside the package is invisible to DSH. Written on every load, unconditionally: these are plugin-managed files, and the skills name the plugin's tools, so a stale copy is exactly what drifts out of sync. A user's own skill directories are never read or removed. Best-effort throughout — an unwritable home directory leaves the tools working and logs one warning.
- **`godot_ping` reports `skills`** — the slugs that were installed, so a session can confirm the knowledge layer landed without inspecting the filesystem.
- **A system-prompt section pointing at the skills** (`godot-bridge:skills`, order 153) — without it the agent has no reason to load them; they are listed with the trigger for each.
- **`scripts/lint-skills.mjs` (capability lint).** Skills are Markdown the model executes as instructions, so a single poisoned line would run verbatim. Seven rules over every `.md` in `skills/`: `url-allowlist` (loopback always allowed, since the interaction server on :9090 is exactly that), `install-command` (package managers, `curl|sh`, `npx <third-party>`), `credential-pattern`, `base64-blob` (160-char threshold, two-line wraps included), `invisible-unicode` (zero-width, bidi, tag block), `prompt-injection-phrase`, `destructive-command`. A skill can exempt a rule with `<!-- lint-allow rule-id: reason -->`; every exemption is printed.
- **`scripts/lint-skills.test.mjs` (25 cases).** A lint that silently stops matching is worse than no lint, because CI stays green — so each rule has a known-bad sample that must fire, and known-good samples that must not. The invisible-character and base64 samples are *constructed* rather than embedded: a zero-width character pasted into source is stripped by editors, which would make the test pass for the wrong reason.
- **`scripts/install-skills.test.mjs`** — proves the install step copies every skill byte-identically and that each `SKILL.md` carries frontmatter the host will index.

### Changed

- `npm run check` now runs the contract check *and* the skill lint, so CI catches a poisoned skill as well as a broken bundle.
- `npm test` runs both test files.

## [0.2.0] - 2026-10-01

### Added

- **`Godot engine path` is now editable in the GUI.** The bundle ships a browser half (`client/client.js`, declared through `dsh.client` in the manifest) that registers this bundle's configuration section — the keyed slot `plugins.bundle.config`, keyed by the package name — so the `godot-bridge` card on the Plugins page shows the path field between its description and its row list, with a **Save** and a **Reset to default** for a path this profile overrides. (The per-row slot `plugins.row.config`, keyed `<package name>#<row id>`, would put the same form one level deeper behind a Configure control on the row; it becomes the right slot once a bundle has several independently configurable rows, which this one does not.) A save travels the same road as the rest of DSH's settings and lands on the same `cordis.patch.yml` row `godot_set_engine_path` writes, so the field, the tool, and a hand-written `config:` block are three views of one value — and a change applies without a restart. Switching that row off withdraws the section with it, because the browser half belongs to that row. This closes the 0.1.8 known limitation below.
- `npm run check` now verifies the browser half as well, so the class of mistake that leaves a bundle without its form fails the build instead of failing silently: the `dsh.client` declaration (its allowed members, `platform: 'web'`, string-array `inject`/`external`, boolean `immediately`), an `exports["./client"]` target that exists and is shipped by `files`, a `window.__ModuleLoader__.load({ id })` registration whose id is the package name, the `slots` service declaration, every `require()` specifier against the web client's platform seed modules plus `dsh.client.external`, a `plugins.bundle.config` key against this bundle's package name, and a `plugins.row.config` key against the rows the patch declares. Slot keys and module requests are read from code, so a comment cannot satisfy a check.

### Changed

- The browser half is inert where DSH cannot host it: 0.1.6–0.1.x already declares these slots but has no settings-form service to read the value through, so the registration sits behind `ctx.inject(['configForms'], …)` and those runtimes keep exactly the previous behaviour (no GUI field, `godot_set_engine_path` and `settings.yaml` as before). A runtime that never scans `dsh.client` (anything older than 0.1.0-rc.7) ignores the new manifest member.

## [0.1.8] - 2026-09-30

### Fixed

- The plugin could not load at all on DSH 0.2.x when installed as a `link:` dependency: the launcher's runtime resolution routes `@deepseek-ai/*` to the installation only for names a linked package declares in its own `peerDependencies` (it reads `peerDependencies` keys, not `dependencies`), and godot-bridge declared none — so `import '@deepseek-ai/dsh-tools'` failed with `ERR_MODULE_NOT_FOUND` and none of the seventeen `godot_*` tools registered. The manifest now declares `@deepseek-ai/dsh-tools` and `@deepseek-ai/schemastery`.
- `godotPath` no longer disappears on DSH 0.2.x: `@deepseek-ai/dsh-settings` dropped `register`, so the settings section silently degraded to a warning and `godot_set_engine_path` always answered that the settings service was unavailable.
- An engine path configured before the 0.1.x → 0.2.x upgrade is carried over automatically instead of silently falling back to `godot` on PATH (typically a version-manager shim, i.e. a different build than the one configured). See the migration note under **Changed**.

### Changed

- Configuration model: `godotPath` is a `.volatile()` field of the plugin's Config, so it appears on the plugin settings page and is read live (volatile fields are updated in place, without remounting the plugin). Writes persist through `ctx.configEditor.edit(...)` into the active profile's `cordis.patch.yml` and hot-recompose — no restart.
- `godot_set_engine_path` now checks that the target exists before writing and reports where it persisted: `persisted: 'profile-patch'` on DSH 0.2.x, `'settings'` on the legacy path.
- Legacy runtimes stay supported: on 0.1.6–0.1.x, where `settings.register` still exists, the plugin keeps using it (the `@deepseek-ai/dsh-tools` peer range is `>=0.1.6-0`). `peerDependenciesMeta.optional` keeps pnpm from installing harness packages from the registry.
- `settings.yaml` migration: DSH 0.2 imports leftover sections by plugin entry id, and this plugin's row id is `tool-godot-bridge`, so a `godot-bridge:` section written on 0.1.x is not carried over. When this runtime has no configured path, the plugin now reads that section and writes the recorded value back through the same profile-patch path as `godot_set_engine_path`, so the engine build configured before the upgrade is used again without re-entering it. An already-configured value is never overwritten, and a recorded path that no longer exists on disk is ignored (that case keeps the PATH fallback and its warning). The restore runs once per plugin load and is best-effort: a rejected write leaves the PATH fallback in place and logs a warning, and never disables a tool.

### Added

- `npm run check` — `scripts/check-plugin-contract.mjs`, a dependency-free static contract check: every bare `@deepseek-ai/*` import must be declared in `peerDependencies`/`dependencies`, `dsh.bundle.patch` must exist and reference the package, `main`/`exports` targets must exist and be covered by `files`, and the entry point must export `name`/`apply` without an `export default`.
- `scripts/diagnose-dsh-resolution.mjs` — a re-runnable diagnostic for the launcher's runtime resolution (bundle layers, skipped bundles, linked roots, per-import result, `--expect ok|fail`); development-only and never published.

### Documentation

- README: new "DSH 0.2+ compatibility and troubleshooting" section (resolution rules, the `link:` peer requirement, a symptom table, the `dsh plugin allow-version` fallback, verification commands) plus corrected config-location wording.
- install: a `link:` local-development section, a rewritten Config section (volatile field, profile-patch write path, legacy fallback, `settings.yaml` migration note), and maintenance steps for the check and diagnostic scripts.
- ARCHITECTURE: new "Dependency contract and runtime resolution" section with its layer diagram.

### Known limitation

- `godotPath` has **no GUI form field** on DSH 0.2. The Plugins page renders a row's configuration form only when that plugin ships a client component registering the keyed slot `plugins.row.config`; no built-in package registers it, and godot-bridge ships no client entry. The Host side is unaffected — `settings.describe()` still projects the field for the `tool-godot-bridge` row, and `godot_set_engine_path` (or a `config:` block on that row) sets it. Tracked as a separate feature request.

## [0.1.7] - 2026-09-07

### Fixed

- Stale autoload was silently defeating port routing: a project whose `autoload/mcp_interaction_server.gd` predated `GODOT_BRIDGE_PORT`/`get_instance_info` kept binding 9090 no matter what port `godot_run_project` requested — so a `port=9092` run reported success but every later `godot_command`/`godot_screenshot` could only find 9090 (issues #4). `ensureInteractionAutoload` now overwrites an out-of-date autoload with the vendored version (the file is plugin-managed infrastructure) and reports `upgraded` when it had to.
- `godot_ping` and error messages report the real probed port instead of a hardcoded `127.0.0.1:9090`.
- `writeProjectFile` scopes its fs policy to the target project directory instead of the session workspace, so autoload/project-file writes are legal for projects outside the workspace.
- Added a `sanitizeLossless` guard at every tool return so a stray `undefined`/`NaN` value degrades to a logged, fixed value instead of a silent `value is not lossless JSON` failure.

## [0.1.6] - 2026-09-01

### Added

- Instance ownership for `godot_run_project`: it probes the port first and ADOPTS an already-running instance of the same project (returns `external: true`) instead of spawning a duplicate that fails to bind — the exact scenario where a user starts a scene in the editor and the LLM then runs the project, which previously produced a silent mis-attach and an orphaned second process.
- A different project on the port triggers an automatic fallback to 9091+ (or the caller's `port` argument) instead of colliding.
- `mcp_interaction_server.gd` now reads `GODOT_BRIDGE_PORT` / `GODOT_BRIDGE_TOKEN` and exposes `get_instance_info` (pid/port/token/project) — the identity basis for ownership detection.
- `godot_stop_project` refuses to terminate adopted (user/editor-launched) instances and explains how to stop safely (F8 in the editor / in-game quit); the plugin never kills processes it did not start. New `godot-bridge:instance-ownership` system-prompt section with the same rule, also forbidding pwsh process-kill workarounds that would take the whole editor down.

### Fixed

- Compatibility with dsh-settings ≥ 0.1.2-alpha: the removed `settingsNamespace` export is gone from the plugin (the plain namespace string is passed to `ctx.settings.register`); settings and tool registration are wrapped defensively so future API drift degrades with a warning instead of failing the host boot.

## [0.1.5] - 2026-08-19

### Added

- `godot_run_headless` tool: bounded headless scene/logic/test runs through the unconfined subprocess service (`godot --headless --path <project> [--quit-after N] [--script <g>]` with a timeout kill), replacing the crash-prone practice of running `godot --headless` through a sandboxed pwsh/bash shell.

### Changed

- `godot_headless_op` / `godot_validate_script` / `godot_export_project` now attach a crash `diagnosis` (`sandbox-crash`, high/low confidence, actionable hint) instead of handing back raw stderr alone, so a sandbox crash can no longer masquerade as a project bug.
- New `godot-bridge:launch-channel` system-prompt section: Godot must always be started through the godot_* tools (unconfined subprocess), never through pwsh/bash (file-sandboxed, signal 11).
- `godot_run_project` description points at `godot_run_headless` for non-interactive headless runs.

### Fixed

- `godot_run_headless` returned `note: undefined` on the normal path; the DSH tool layer rejects any `undefined` property ("value is not lossless JSON") and discarded the entire result. `note` is now only present on timeout, and `exit_code` is normalized so every return field is lossless JSON.
- `godot_validate_script` error entries now use `null` (not `undefined`) for missing file/line locations.

## [0.1.4] - 2026-08-16

### Fixed

- Restore the `timer` injection dropped in 0.1.3: `ctx.timeout()` is a mixin of the timer service whose getter reads `ctx.timer`, so its removal broke `godot_run_project` / `godot_command` / `godot_screenshot` with `cannot get property "timer" without inject`.

## [0.1.3] - 2026-08-15

### Added

- `godot_set_engine_path` tool: the model asks the user for their Godot executable and persists it into settings (schema- and existence-validated, hot-reloaded — no restart), closing the "no engine configured" guidance loop.

### Changed

- `godotPath` is now a user-facing settings value (the Web plugin-config page or the `godot-bridge:` section of `settings.yaml`), not a `cordis.patch.yml` row config; the plugin author no longer presets a path (Godot is a portable exe that can live anywhere).
- Godot executable resolution order: per-tool `godot_path` argument → the `godotPath` setting → the `godot` command on PATH. Nothing to configure when `godot` is on PATH.
- Existence validation moved from an `apply`-time `throw` (which failed the whole fiber) to the settings `validate` hook, so a bad path can no longer disable the pure-file tools.

### Fixed

- Tool descriptions no longer mislabel the config location as `$DSH_HOME/settings.yaml`; they now point at the settings section the code actually reads.

### Removed

- Redundant `timer` injection and `console.log` noise (now `ctx.logger`).

## [0.1.2] - 2026-08-15

### Fixed

- The update notice now reliably reaches the model: `systemPrompt` is injected (was a lazy `ctx.get` that could miss the service) and the notice text is an explicit instruction to inform the user, so the model surfaces "update available: installed X, latest Y" in every session.
- `godot_ping` reports `plugin_version` / `latest_version` / `update_available` for on-demand checks.

## [0.1.1] - 2026-08-15

### Added

- Boot-time update notice: a best-effort version check against the repo's `main`-branch `package.json` (`raw.githubusercontent.com`, 5 s timeout, silent on failure/offline). When a newer release exists it registers a system-prompt section; the `repository` field in `package.json` redirects the check for forks.

### Fixed

- `godot_command`'s `timeout_ms` was a no-op: the one-shot node bridge hard-capped at 20 s. The timeout is now threaded through as `argv[3]` (fallback 20 s), so `godot_ping`, `godot_run_project`'s readiness poll, and async commands honor their timeouts.

### Changed

- Dropped stale headless-script fallback candidates (`<project>/tools/godot-bridge/`, `../godot-mcp/src/scripts/`) from the pre-bundle deployment; the module-relative copy is the only source.

## [0.1.0] - 2026-08-15

Initial release — a standard DSH bundle that replaces the godot-mcp MCP server with native agent tools.

### Added

- Fifteen `godot_*` tools:
  - process: `godot_run_project` / `godot_stop_project` / `godot_get_debug_output` / `godot_ping`
  - runtime control: `godot_command` (every interaction-server command), `godot_screenshot`
  - headless: `godot_headless_op` (16 ops) / `godot_validate_script`
  - project editing: `godot_set_project_setting` / `godot_manage_autoloads` / `godot_manage_input_map` / `godot_manage_export_presets` / `godot_create_script` / `godot_create_project` / `godot_export_project`
- Standard DSH bundle form: `defineTool` from `@deepseek-ai/dsh-tools` + `ctx.tools.register`; `dsh.bundle` manifest installs with `dsh plugin --profile web add github:Smalldy/godot-bridge`.
- Vendored game-side assets: `mcp_interaction_server.gd` (in-game TCP autoload), `godot_operations.gd`, `validate_script.gd`.
- Correct Godot 4 keycodes in `godot_manage_input_map` (fixes godot-mcp's Godot 3 baseline bug).
- Bilingual documentation (README / install / ARCHITECTURE / COVERAGE) incl. install and uninstall guides; `cordis.patch.yml` included in published `files`.

[0.2.0]: https://github.com/Smalldy/godot-bridge/compare/v0.1.8...v0.2.0
[0.1.8]: https://github.com/Smalldy/godot-bridge/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/Smalldy/godot-bridge/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/Smalldy/godot-bridge/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/Smalldy/godot-bridge/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/Smalldy/godot-bridge/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/Smalldy/godot-bridge/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/Smalldy/godot-bridge/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Smalldy/godot-bridge/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Smalldy/godot-bridge/releases/tag/v0.1.0
