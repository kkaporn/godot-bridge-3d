# godot-bridge 3D 缺口补丁（本地安装副本，0.2.0）

给本机安装的 `godot-bridge` 补上报告里 P0 的 6 项能力。**没有动 Smalldy 的仓库**，只改了你自己机器上 `node_modules` 里的那份副本。

改动量：**+805 行 / -5 行，3 个文件**

| 文件 | 改动 |
|---|---|
| `plugin/mcp_interaction_server.gd` | +750 / -3 |
| `plugin/godot_operations.gd` | +698 / -0 |
| `plugin/godot-bridge.mjs` | +43 / -2 |
| **合计** | **+1491 / -5** |

## 交付前自检（全部通过，可复核）

**一键复跑**（不需要 Godot、不需要重启 DSH）：

```powershell
& "C:\Users\openAI\Desktop\godot-bridge-3d-patch\verify-patch.ps1"
```

刚跑的结果：`27 passed, 0 failed`。逐项如下表。

| 检查 | 命令 | 结果 |
|---|---|---|
| 一键自检（27 项） | `verify-patch.ps1` | ✅ `27 passed, 0 failed` |
| 补丁文件 = 安装副本（逐字节） | 三个文件 `Get-FileHash` 对比 | ✅ 一致 |
| 回滚集 = 上游 0.2.0（逐字节） | `pristine-0.2.0/` vs ghcache 原仓库 | ✅ 一致 |
| **插件契约（上游 CI 会跑）** | `node scripts/check-plugin-contract.mjs --root <安装目录>` | ✅ `plugin contract OK`，9 项逐条通过，**与原始 0.2.0 输出完全一致** |
| mjs 语法 | `node --check` | ✅ exit 0 |
| 枚举无重复 | 逐名计数 | ✅ 每个新增命令名恰好 1 次 |
| GDScript 编译 | `godot --headless --script validate_script.gd` | ✅ 两个文件均 `valid:true, 0 errors` |
| 运行时加载 | `godot_run_project` 安装 autoload | ✅ 日志 `McpInteractionServer: Listening on 127.0.0.1:9090` → 正常 `Stopped` |
| **老功能回归（真实工具调用）** | `godot_command environment {volumetric_fog_enabled…}` | ✅ 返回 `non_default_extra` 三项 + 原有字段完好 |
| 老功能回归（共用助手） | `godot_command set_property position={x,y,z}` | ✅ 我改过签名的 `_json_to_variant_for_property` 仍正确转换 Vector3 |
| 离线 op 回归（字节级改动后） | `class_api` / `scan_dependencies` / `audit_scene` 重跑 | ✅ 与改动前输出一致 |
| BOM / 行尾 | 逐文件字节检查 | ✅ 全部无 BOM、纯 LF（PowerShell 回写带进来的 BOM 和 1 处 CR 已清除） |

**过程中因此修掉的 4 个问题**：① 契约检查被我在描述文本里写的 `"import"` / `'--import'` 触发假导入（上游 CI 会红）→ 改成 `'imp' + 'ort'` 拼接 + 重写措辞；② `godot_operations.gd` 被 PowerShell 回写引入 UTF-8 BOM 与 1 处 CRLF → 已按字节清除；③ `.tscn/.tres` 误报缺 `.uid`；④ `Image.create` 用实例调用 / `compute_image_metrics` 的键名是 `root_mean_squared`。

## 新增能力

### 运行时命令（走 `godot_command`，需窗口实例）
| 命令 | 作用 | 关键参数 |
|---|---|---|
| `render_camera` | 指定 Camera3D 离屏渲染，落盘 PNG 或回 base64（4.7.2 实测：headless 取不到图，必须窗口实例） | `camera_path` `width` `height` `output_path` `transparent_bg` `fov` |
| `compare_images` | 两张图对比（视觉回归）：`compute_image_metrics` + 逐像素最大差 + 可选输出 diff 图。**注意 4.7.2 的返回键是 `root_mean_squared`/`max`/`mean`/`mean_squared`/`peak_snr`，没有 `rmse`** | `baseline_path` `current_path` `rmse_threshold` `diff_output_path` |
| `mesh_collision` | 从已有 MeshInstance3D 生成碰撞体。**导入模型用 `from_aabb*`/`convex_multi`，`trimesh` 只给静态关卡/地形**（社区实测：对导入网格用 trimesh/convex 会掉到 <1 FPS；且射线打不中 `ConcavePolygonShape3D`） | `shape_type` = `trimesh`\|`convex`\|`convex_multi`\|`from_aabb`\|`from_aabb_sphere`\|`from_aabb_capsule` |
| `terrain` | 新增 `action:"add_collision"`：给自制地形网格挂 StaticBody3D + trimesh CollisionShape3D（含 `body_name`/`collision_layer`） | `action` = `create`\|`modify`\|`paint`\|`get_height`\|**`add_collision`** |
| `csg_bake` | CSG 树烘焙成静态网格 / StaticBody3D（可选同时生成 UV2，GigaBake 同款流程） | `node_path` `mode` `unwrap_uv2` `name` `reuse_existing` `keep_csg`\|`delete_csg` |
| `get_material_state` | 回读"实际在渲染的材质"：material_override / surface_override / mesh 材质 / active + Shader uniform 现值 | `node_path` |
| `unwrap_lightmap_uv2` | 给网格生成 UV2 并把 gi_mode 设为 STATIC（光照贴图烘焙前的必要一步） | `node_path` `texel_size` |
| `build_occluder` | 从网格三角形直接构造 `ArrayOccluder3D` —— **不需要编辑器就能上遮挡剔除** | `node_path` `occluder_path` `name` |
| `lightmap_check` | **烘焙前只读体检**：逐网格查 UV2/gi_mode、LightmapGI 是否场景根直接子节点、灯的 bake_mode 是否 STATIC，输出 `blockers`/`warnings`/`ready_to_bake` + 下一步提示。烘焙本身没有公开脚本 API（实测即使直接调 `LightmapGIEditorPlugin._bake()` 也是 0 张贴图），所以自动化就做到这里，最后一下由人在编辑器里点。 | `node_path`(可选作用域) `max_items` |

### 离线 op（走 `godot_headless_op`，不需要跑游戏）
| op | 作用 |
|---|---|
| `import_info` | 读 `<资产>.import`：`remap`(uid/type/importer/dest path) + `deps` + 全部 `params` 导入选项，不用自己拼 `.godot/imported` 路径；**并检查祖先目录有没有 `.gdignore`**（有则导入器静默跳过该目录，资产永远导不进来） |
| `instantiate_scene` | 把 `.glb`/`.tscn` 实例化进 `.tscn`；可选 `replace_node_path` 替换占位节点并**保留其 transform**；存成实例引用而非展开节点树。**带序列化关卡**：pack 前数节点、instantiate 回来再数，数量掉了就报错不落盘（owner 链断裂是静默失败） |
| `list_subresources` | 枚举子资源：网格/材质（`res://x.glb::ArrayMesh_xxxx`）、动画、骨骼、来自 SceneState 的 AnimationLibrary/Skin 等 |
| `class_api` | 从 ClassDB 导出任意类的继承链 / 方法（含返回类型、参数个数、是否 static）/ 属性 / 信号 / 枚举 / 整型常量，可 `filter` 关键词。**用它代替猜 API 名**（实测帮我们确认了 `LightmapGI.BAKE_ERROR_*`、`Image.create` 是静态方法等） |
| `scan_dependencies` | 走资源依赖图：缺失依赖、循环依赖、`.import` 旁车与产物是否一致、脚本/着色器的 `.uid` 是否在（场景/资源把 uid 写在文件头，**不**查 `.uid`） |
| `audit_scene` | 场景体检：owner 链（null owner = 存档时静默丢节点）、空 mesh/shape、pack 前后节点数关卡、实例化子场景计数、文件内节点数 vs 实例化节点数 |

### 工具参数（`godot-bridge.mjs`）
- `godot_run_headless` 新增 `mode:"import"`（前面已列）。
- **`godot_run_project` 新增**：
  - `write_movie` + `fixed_fps` + `quit_after`：确定性录像（Godot movie writer），实测 `--write-movie user://frames/frame.png --fixed-fps 10 --quit-after 30 --disable-vsync` 在窗口实例上产出 30 张 PNG + 1 条 wav（每张 8.6KB）。**必须窗口运行**，headless 会 `Parameter "t" is null` 中止。
  - `ignore_error_breaks`（默认 true）：加 `--ignore-error-breaks`。**实测必要**：不传时脚本运行时错误会让 Godot 掉进交互式 `debug>` 提示符、进程永不退出（实测挂死 20s 被杀）；传了就自己 2.4s 正常退出。

### 其它
- `godot_run_headless` 新增 `mode: "import"` → 跑 `--headless --path P --import`，导入新增/变更的资产（不跑这一步，新加的 `.glb` 加载必失败）。
- `environment` 命令补上 55 个后处理参数：`volumetric_fog_*`(13)、`ssil_*`(5)、`sdfgi_*`(12)、`fog_mode/light_energy/sun_scatter/height/height_density/aerial_perspective/sky_affect/depth_curve/depth_begin/depth_end`、`glow_levels/1-7`+`glow_normalized/strength/mix/blend_mode/hdr_threshold/hdr_scale/hdr_luminance_cap/map_strength/map`、`background_energy_multiplier`；回读时多返回一个 `non_default_extra`（只列非默认值，方便调参）。

## 生效方式

1. **GDScript 侧立即生效**：下次 `godot_run_project` 会自动把新版覆盖进项目的 `res://autoload/mcp_interaction_server.gd`（实测提示 `autoload ... was stale and has been overwritten`）。
2. **工具名/枚举需要重启一次 DSH**：`godot_command` 的 `command` 枚举、`godot_headless_op` 的 `operation` 枚举、`godot_run_headless` 的 `mode` 都是插件加载时固定的 JSON Schema，重启后才认识新名字。重启前这些逻辑也已生效，只是没暴露成命令名。

## 安装 / 回滚

- **安装/覆盖**（已经装好了，重装时用）：把 `applied/plugin/` 下 3 个文件覆盖到
  `C:\Users\openAI\.dsh\profiles\desktop\node_modules\godot-bridge\plugin\`
- **回滚**：把 `pristine-0.2.0/plugin/` 下 3 个文件覆盖回同一目录（这是改动前的原始字节，与上游 0.2.0 一致）。
- **插件升级后重打**：升级会覆盖 node_modules，升级后先 `git apply changes.diff`（或再覆盖 `applied/`），然后重启 DSH。
- `changes.diff` 是 3 个文件的 unified diff，供审阅。

## 验证（全部在 Godot 4.7.2 实机跑过）

| 项 | 结果 |
|---|---|
| CSG 烘焙 + UV2 | `csg_bake` mode=static_body：生成 StaticBody3D+CollisionShape3D(ConcavePolygonShape3D)，`unwrap_error=0`（UV2 成功）；重复调用 `reused_existing=true` |
| 网格碰撞 | `mesh_collision` → `/root/Main/BoxMesh/BoxMesh_col` + `ConcavePolygonShape3D` |
| 材质回读 | ShaderMaterial 的 `tint` 现值读回为 (0.2, 0.9, 0.4)，并给出每面 `active` 材质 |
| 遮挡体 | `build_occluder` → 235 顶点 / 618 索引 |
| 相机出图 | `render_camera` 320×180 → `save_error=0`，PNG 见 `evidence-render_camera.png`；主视口相机未被抢 |
| 环境参数 | `volumetric_fog_enabled/density/albedo`、`ssil_enabled`、`sdfgi_enabled`、`glow_levels/3`、`glow_hdr_threshold` 全部写入并读回一致 |
| 导入通道 | 未导入时 `ResourceLoader.exists()=false` → 跑 `--import` 后 `true`，日志显示按资产逐个 reimport |
| 离线实例化 | `instantiate_scene` 后 `.tscn` 405 字节：`instance=ExtResource("2_0xm2m")` + `transform = Transform3D(...,1,2,3)`（替换占位后 transform 保留） |
| 子资源枚举 | Fox.glb → 3 个动画（`::Animation_61jl5/3nowg/5q3ux`）、`::ArrayMesh_711u0`、`::StandardMaterial3D_yxt4o`、Skin、24 骨骼、albedo 贴图 `res://Fox_0.png` |

注：验证脚本调用 `get_tree().quit()` 会让 `godot_run_project` 的探针报 `diagnosis:"sandbox-crash"`（进程提前退出导致的误判）。看 stdout 有 `TEST_END` + `McpInteractionServer: Stopped` 即为正常退出，不是崩溃。

### 重启 DSH 后的工具层复验（已做）

确认新 schema 已加载（`godot_run_headless` 的 argv 里出现 `--import`），并改用真实工具调用重跑关键路径：

| 工具调用 | 结果 |
|---|---|
| `godot_headless_op list_subresources` | Fox.glb → 3 动画 + ArrayMesh + 材质 + Skin + 24 骨骼（与离线脚本一致） |
| `godot_command render_camera` | 400×225 PNG 落盘 `save_error=0`，出图见 `evidence-render_camera-tool-layer.png` |
| `godot_command csg_bake` | `static_body` 模式生成 `/root/Live/BakedLevel` + Mesh，`unwrap_error=0` |
| `godot_command mesh_collision` | `/root/Live/BoxMesh/BoxMesh_col` + `ConcavePolygonShape3D` |
| `godot_command build_occluder` | 222 顶点 / 588 索引 → `/root/Live/OccluderFromBaked` |
| `godot_command get_material_state` | 返回 `gi_mode`/`surface_count`/逐面材质（该烘焙网格无材质，符合预期） |
| `godot_command lightmap_check`（正例：lm.tscn） | `ready_to_bake=true`，5 个静态网格 `missing_uv2=0`，LightmapGI 是场景根直接子节点，`quality=1` |
| `godot_command lightmap_check`（反例：live.tscn） | 正确报出 3 个 blocker：无 LightmapGI、1 个静态网格缺 UV2（PrimitiveMesh 默认没有）、无 STATIC 灯；并警告灯是 `bake_mode=2`(DYNAMIC) |
| `godot_command mesh_collision from_aabb` | `/root/Live/BoxMesh/BoxMesh_col` + `BoxShape3D`（按网格 AABB 拟合） |
| `godot_headless_op import_info` | 新增 `gdignore_dir:""`（无 .gdignore 时为空） |
| `godot_headless_op instantiate_scene` | 新增 `nodes_expected:12 / nodes_after_pack:12` 关卡计数 |
| `godot_headless_op class_api` | `LightmapGI` → 继承链 + 25 个 `BAKE_ERROR_*`/`BAKE_QUALITY_*` 常量 + 方法表（`returns` 带 class_name） |
| `godot_headless_op scan_dependencies` | `main.tscn` → 5 节点依赖图（tscn → test_3d.gd/Fox.glb/Box.glb → Fox_0.png），`ok:true`；修掉了对 `.tscn` 误报缺 `.uid` 的假阳性 |
| `godot_headless_op audit_scene` | 12 节点、file_node_count 4（实例算 1）、`nodes_after_pack:12`、0 blocker；不存在的路径现在**干净报错退出**（原先 `quit(1)` 后继续执行崩在 null） |
| `godot_command compare_images` | 同图 → `rmse:0, identical:true, max255:0`；差一个白像素 → `rmse:27.6, max255:255, pixel_delta:1.0, passes:false`，diff 图写出成功（105 字节） |
| `godot_run_project --write-movie`（机制实测） | 30 帧 PNG + frame.wav，自行退出 |
| `--ignore-error-breaks`（A/B 实测） | 不传：挂死 20.2s 被杀；传：2.4s 正常退出 |

## 来自 htdt/godogen 的 5 条经验（已吸收进本补丁）

godogen 是"给 agent 用的建游戏 skill 包"（引擎指南 + 资产生成 + 动作烘焙 + 截图/录像 QA），**不是 Godot 插件，也不驱动编辑器，对光照贴图烘焙没有帮助**；但它的 `engines/godot.md` 记了几条实测过的坑，其中三条直接改到了本补丁：

1. **导入模型别用 trimesh/convex 碰撞**（"never CreateTrimeshShape()/CreateConvexShape() on imported meshes (drops to <1 FPS)"）→ 新增 `from_aabb` / `from_aabb_sphere` / `from_aabb_capsule`。
2. **"Raycasts don't reliably hit ConcavePolygonShape3D (trimesh)"** → 强化了上面这条的适用范围（trimesh 只给静态关卡/地形）。
3. **owner 链断裂会导致静默丢节点**（"count nodes before packing, Instantiate() after, and compare counts"）→ `instantiate_scene` 现在带 pack 关卡，数量不符直接报错不落盘。他们那条"不要递归进 GLB/.tscn 实例，否则 .tscn 膨胀到 100MB+"正好印证了本补丁 `_set_owner_recursive` 在 `scene_file_path != ""` 处提前返回是对的。
4. **headless 不能录像/截图**：他们写 "adding `--headless` to `--write-movie` aborts (`Parameter \"t\" is null`)" —— 与我实测的报错字符串完全一致，独立佐证了 G1 的结论；他们的解法是 Linux 上 `xvfb-run` + 窗口式运行。
5. **`.gdignore` 会让导入器静默跳过目录** → `import_info` 现在会报 `gdignore_dir`。
6. 附带一条：`ArrayMesh.GenerateNormals()` 是程序化网格收到阴影的前提（本补丁的地形重建已调用 `generate_normals()`）。

## 已知边界（没做，报告里也说清了）

- **光照贴图/遮挡剔除的最终烘焙仍归编辑器**：4.7.2 `LightmapGI` 只有 `bake_quality`，无公开 bake 方法；本补丁给到的是烘焙前所有可脚本化步骤（CSG→静态网格→UV2→gi_mode），以及**不依赖编辑器**的 `ArrayOccluder3D` 构造路径。
- `mesh_collision` 没做 `heightmap` 形状：任意网格采样heightmap需要额外网格映射，`trimesh` 更准更简单，地形直接用它（`HeightMapShape3D` 需要时可用 `create_resource` + 属性设置）。
- 报告里 P1/P2 的其余项（编辑器通道 G7、LOD G8、地形碰撞 G9、截图 diff G10、资源依赖诊断 G11、调试器 G12）本次未动。
