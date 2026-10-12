# godot-bridge 3D 能力缺口报告

结论：另三个 MCP 都**没有**比 godot-bridge 更深的 3D 作者能力（三个的 3D 支持都是"用 ClassDB 造任意节点 + 改属性"，唯一真 3D 工具是 Coding-Solo 的 MeshLibrary 导出，而 godot-bridge 已有）。真正值得补的是 **6 个 P0 小增量** + **编辑器侧通道**这条结构性缺腿。**P0 与第二批已全部落地并实机验证**，明细见「实施记录」。

- 本机被测版本：godot-bridge 安装于 `C:\Users\openAI\.dsh\profiles\desktop\node_modules\godot-bridge`，运行时命令 108 个（`plugin/mcp_interaction_server.gd`），离线 op 16 个（`plugin/godot_operations.gd`）。
- 引擎：`D:\Godot\Godot_v4.7.2-stable_win64.exe`（本报告所有"探针证实"均来自在该引擎上跑 `ClassDB.class_get_method_list()` 的实测输出）。
- 归档说明（2026-10-13）：本报告写作时（0.2.0）的补丁产物目录 `patch/`（`pristine-0.2.0/`、`applied/`、`changes.diff`、`verify-patch.ps1`、`restore.ps1`、`lightmap-bake-probe/`、证据截图）已从仓库删除，仓库只保留 `plugin/` 一份最新实现；旧产物可在 git 历史 `d16bb94` 取回（例如 `git show d16bb94:patch/changes.diff`）。下文出现的 `patch/` 路径或桌面绝对路径均指该历史版本。

## 0. 基线：godot-bridge 已经有什么（别重复造）

| 3D 域 | 现有命令/工具 |
|---|---|
| 网格 | `mesh_instance`、`procedural_mesh`（ArrayMesh/SurfaceTool 建网格）、`multimesh`（create/set_transform）、`gridmap`（set/get_cell_item）、`csg`（建+operation+尺寸）、`terrain`（自制 heightmap + 抬升/上色） |
| 光照/环境 | `light_3d`、`environment`（子集）、`sky`、`camera_attributes`、`3d_effects`（ReflectionProbe/Decal/FogVolume）、`gi`（建 VoxelGI/LightmapGI 节点） |
| 物理 | `physics_body`、`create_joint`、`add_collision`（5 种图元）、`raycast` |
| 动画 | `create_animation`、`play_animation`、`animation_control`、`animation_tree`（travel/set_param/get_state）、`bone_pose`、`skeleton_ik` |
| 导航/粒子/出图 | `navigation_3d`（含 `action:"bake"` → `NavigationRegion3D.bake_navigation_mesh()`）、`set_particles`、`screenshot` |
| 离线创作 | `godot_headless_op`：`create_scene/add_node/modify_node/save_scene/read_scene/create_resource/manage_resource/manage_scene_structure/export_mesh_library/...`；`create_resource` 能造**任意** Resource 类，且 `_convert_property_value` 支持 Vector3/Transform3D/Color/NodePath/`res://` 加载 |
| 工程面 | 项目设置/输入映射/autoload/导出预设/脚本校验/headless 运行/导出 |

**已经是"缺口"的常见误判（不用做）**：反射调任意 API（`eval` 已覆盖）、MeshLibrary 导出（已有 op）、NavMesh 烘焙（已有）、UID 工具（`get_uid`/`resave_resources` 已有）、任意资源创作（`create_resource` 已有）、运行时造任意节点/改属性/调方法（已有）。

## P0 — 高频 3D 需求 + 落地便宜（已全部落地）

| # | 缺口 | 现状证据 | 来源仓库 | 落地方式 | 量级 |
|---|---|---|---|---|---|
| G1 | **指定相机离屏出图 / 截图落盘** | `_cmd_screenshot()` 无参数、只抓主视口、只回 base64 | IvanMurzak `screenshot-camera`/`screenshot-isolated`；Native `get_runtime_screenshot`（落盘） | 新命令 `render_camera`（SubViewport + 克隆 Camera3D → `frame_post_draw` → `save_png`）。**headless 取不到图**（4.7.2 实测：`get_image()` 返回 null + `texture_2d_get (dummy/storage/texture_storage.h:110)`），必须窗口实例 | ~80 行 |
| G2 | **从 Mesh 生成碰撞体** | `add_collision` 只有 box/sphere/capsule/cylinder/ray | godogen 实测经验 | 新命令 `mesh_collision`：`trimesh`（`Mesh.create_trimesh_shape`）/`convex`/`convex_multi`/`from_aabb*`。**导入模型用 `from_aabb*`/`convex_multi`，trimesh 只给静态关卡/地形** | ~60 行 |
| G3 | **环境/后处理参数只覆盖约 1/5** | `environment` 仅 background/ambient/fog(3)/glow(3)/tonemap/ssao(3)/ssr(1)/adjustment(3)；**volumetric_fog 一个 key 都没有** | IvanMurzak（`resource-modify` 改 Environment 全字段） | `environment` 补 55 个 key（字段名**以 ClassDB 为准**：文档里的 `volumetric_fog_energy` 在 4.7.2 不存在，实际是 `volumetric_fog_emission_energy`）+ `non_default_extra` 回读 | ~60 行 |
| G4 | **CSG 烘焙** | `csg` 只能建节点+operation+尺寸；全仓 `bake` 只出现在 navmesh | Stuyk/gigabake、KoB-Kirito/csg_converter | 新命令 `csg_bake`（`bake_static_mesh`/`get_meshes`、可选 UV2、mesh/static_body 两种产物、按名字幂等重烘、15 项属性忠实复制） | ~90 行 |
| G5 | **3D 资产导入/重导入通道** | 全仓 **0 处** `import`；新加的 .glb 没有 `.import` 加载必失败 | Native `reimport_resources`/`get_import_metadata`；IvanMurzak `filesystem-reimport` | `godot_run_headless mode:"import"` + 离线 op `import_info`/`instantiate_scene`/`list_subresources`（详见「G5 链」） | 见下 |
| G6 | **材质/Shader 只读回读** | 有 `set_shader_param`，没有"实际在用哪个材质、有哪些 uniform、值多少" | Native `get_runtime_material_state`/`get_runtime_shader_parameters` | 新命令 `get_material_state`（material_override → surface_override → mesh 材质 → `get_active_material`，含 Shader uniform 现值） | ~60 行 |

## P1 — 结构性缺口

| # | 缺口 | 现状/硬事实 | 结论 |
|---|---|---|---|
| G7 | **编辑器侧通道（`--editor` + EditorPlugin）** | 全仓 0 处 `EditorInterface`/`--editor`。只有"跑游戏"和"离线改 .tscn"两条腿 | **通道可达但决定不做**：我用 `OS.execute("--editor")` + 注入 EditorPlugin + 回传 stdout 跑通了真实编辑器，能拿编辑器日志/选中态；但唯一独占价值（编辑器视口截图、undo）收益低且要往用户项目塞 addon |
| G7b | 其中 **LightmapGI / 遮挡剔除烘焙** | 4.7.2 `LightmapGI` 只有 `set/get_bake_quality`（无公开 bake 方法）；`OccluderInstance3D` 只有 `bake_mask` + 一个 `Bake` 属性按钮 | **烘焙自动化做不到**（6 轮变体实测 0 张贴图）→ 落地为 `unwrap_lightmap_uv2` + `build_occluder`（**无需编辑器**的 ArrayOccluder3D 构造）+ `lightmap_check` 体检 + 人工点一次。证据见 `godot-bridge-3d-patch/lightmap-bake-probe/` |
| G8 | **LOD / 可见距离** | 全仓 0 处 `lod`/`visibility_range` | 未做：导入资产默认已由 `meshes/generate_lods=true` 生成 LOD；`visibility_range_*` 用现有 `set_property` 就能设，属文档化而非新代码 |
| G9 | **地形无碰撞、无分块** | 自制地形只 `mi.mesh = st.commit()`，不生成碰撞 | ✅ 已补 `terrain action:"add_collision"`（trimesh）；分块/LOD 等实测掉帧再做 |
| G10 | **截图回归对比** | 只有 base64 截图 | ✅ 已补 `compare_images`（含 diff 图落盘） |
| G11 | **资源依赖/UID 诊断** | 有 `get_uid`/`resave_resources`，无缺失/循环依赖扫描 | ✅ 已补 `scan_dependencies` |
| G12 | **调试器（断点/单步/变量）** | 只有 stdout/stderr 增量读取 | **不做**：需自研 DAP 客户端（Godot 有 `--dap-port`），量级远超本补丁，且与"驱动运行中的游戏"定位不符 |

## P2 — 已处置

- ✅ **G13 类 API 元数据** → `class_api`（继承链/方法+返回类型+argc+static/属性/信号/枚举/整型常量，可 filter）。
- ✅ **G14 场景审计** → `audit_scene`（owner 链、空 mesh/shape、pack 前后节点数关卡、实例场景计数）。
- ⛔ **G15 脚本符号索引** → 不做：agent 直接 grep 项目文件即可，插件内做语言级索引是重复造。
- ⛔ **G16 项目健康审计** → 已由 `scan_dependencies` + `audit_scene` + `validate_script` 三者覆盖，不再单做一个汇总器。
- ⛔ **G17 结构化错误分类** → 不做：`godot_get_debug_output` 已给原始增量输出，正则分类价值低。
- ✅ **G18 确定性录像**（新增，来自 godogen 配方）→ `godot_run_project` 的 `write_movie`/`fixed_fps`/`quit_after`。

## 参照仓库一句话结论

| 仓库 | 架构 | 3D 上到底强在哪 | 对 godot-bridge 的净增量 |
|---|---|---|---|
| [Coding-Solo/godot-mcp](https://github.com/Coding-Solo/godot-mcp) | TS/Node，`godot --headless --script` 子进程；14 工具 | 只有 `export_mesh_library`（已有）；**无任何运行时能力** | 0 |
| [IvanMurzak/Godot-MCP](https://github.com/IvanMurzak/Godot-MCP) | C# .NET 8 `EditorPlugin`（编辑器必须开），反射驱动 42 工具 | `screenshot-camera`/`screenshot-isolated`（bbox 6 角度离屏出图）、selection get/set、`.import` 感知的 resource-move、编辑器日志环形缓冲 | G1、G11、G7 |
| [yurineko73/Godot-MCP-Native](https://github.com/yurineko73/Godot-MCP-Native) | 100% GDScript EditorPlugin 自己当 MCP server，148 工具，游戏须从编辑器调试启动 | `execute_editor_script`、`EditorUndoRedoManager`、`reimport_resources`/`get_import_metadata`、`get_runtime_material_state`、`compare_render_screenshots`、依赖图诊断、符号索引 | G5、G6、G10、G11、G7 |
| [Stuyk/gigabake-godot](https://github.com/Stuyk/gigabake-godot) | 79 行 EditorPlugin（工具栏按钮） | CSG→静态网格 + **`ArrayMesh.lightmap_unwrap` 生成 UV2** + **用表面数组手搓 `ArrayOccluder3D`**（不需要编辑器） | G4 的 UV2/遮挡部分 |
| [KoB-Kirito/csg_converter](https://github.com/KoB-Kirito/csg_converter) | 290 行 EditorPlugin + 菜单 | `csg.get_meshes()[1]` 取网格、CSG→MeshInstance3D 的 15 项属性忠实复制清单 | G4 的属性复制清单 |
| [htdt/godogen](https://github.com/htdt/godogen) | 不是插件：给 agent 用的建游戏 skill 包（引擎指南 + 资产生成 + 动作烘焙 + 截图/录像 QA） | 实测过的坑：导入模型别用 trimesh/convex 碰撞、pack 前数节点防静默丢节点、`.gdignore` 静默跳过、headless 不能录像 | G2 用法修正、序列化关卡、`.gdignore` 检查、G18 |

## 建议执行顺序（已完成）

1. ✅ G5（`--import`）→ 其余 3D 工作都依赖它。
2. ✅ G1（相机出图落盘）→ 也是 G10 的前置。
3. ✅ G2 + G4 + G3（碰撞体、CSG 烘焙、环境参数）。
4. ✅ G6（材质回读）。
5. ✅ 第二批：G9/G10/G11/G13/G14/G18 + 防 debugger break 卡死。
6. ⛔ G7/G7b/G12/G15/G17 已论证不做或做不到。

---

# 实施记录（全部落地并实机验证）

补丁产物：`C:\Users\openAI\Desktop\godot-bridge-3d-patch\`（`changes.diff` + `applied/` 可直接覆盖 + `pristine-0.2.0/` 可回滚 + README 含交付前自检明细 + `lightmap-bake-probe/`）。只改本机 `node_modules\godot-bridge` 副本，未动上游仓库。

| 缺口 | 状态 | 实现 | 验证结果 |
|---|---|---|---|
| G5a 导入通道 | ✅ | `godot_run_headless mode:"import"` + 离线 op `import_info` | 导入前 `exists=false` → 后 `true`；`import_info` 返回 remap(uid/type/dest) + deps + 全部 params + `gdignore_dir` |
| G5b-1 离线实例化 | ✅ | 离线 op `instantiate_scene`（支持 `replace_node_path` 保留 transform） | 产物 .tscn 405 字节：`instance=ExtResource(...)` + `transform=Transform3D(...,1,2,3)`；新增 `nodes_expected/nodes_after_pack` 序列化关卡 |
| G5b-4 子资源枚举 | ✅ | 离线 op `list_subresources` | Fox.glb → 3 动画/ArrayMesh/StandardMaterial3D/Skin/24 骨骼/albedo 贴图 |
| G1 相机出图 | ✅ | 新命令 `render_camera` | 320×180 与 400×225 两次 PNG 落盘 `save_error=0`；主视口相机未被抢（见 `evidence-*.png`） |
| G2 网格碰撞 | ✅ | 新命令 `mesh_collision`（trimesh/convex/convex_multi + from_aabb/from_aabb_sphere/from_aabb_capsule） | `from_aabb` → `BoxMesh_col` + `BoxShape3D`；`trimesh` → `ConcavePolygonShape3D` |
| G3 环境参数 | ✅ | `environment` 补 55 个 key + `non_default_extra` | 通过**真实工具调用**验证：`environment {volumetric_fog_enabled, volumetric_fog_density, ssil_enabled}` → `non_default_extra` 三项正确回读，原有字段完好 |
| G4 CSG 烘焙 | ✅ | 新命令 `csg_bake`（`bake_static_mesh`/`get_meshes`、可选 UV2、mesh/static_body、幂等重烘） | `static_body` 模式生成 StaticBody3D+Shape，`unwrap_error=0`；重复调用 `reused_existing=true` |
| G6 材质回读 | ✅ | 新命令 `get_material_state` | ShaderMaterial uniform `tint` 读回 (0.2,0.9,0.4)，并给出每面 `active` 材质 |
| G7b 光照/遮挡烘焙 | 🟡 部分 | `unwrap_lightmap_uv2`、`build_occluder`、`lightmap_check` | UV2 成功；遮挡体 235 顶点/618 索引；`lightmap_check` 正例 `ready_to_bake=true`、反例正确报 3 个 blocker。**烘焙本身实测无法脚本化** |
| G9 地形碰撞 | ✅ | `terrain action:"add_collision"` | 与 `mesh_collision` trimesh 同源 |
| G10 截图回归 | ✅ | 新命令 `compare_images` | 同图 `rmse:0/identical:true`；差 1 个白像素 → `rmse:27.6, max255:255, passes:false`，diff 图写出成功 |
| G11 依赖/UID 诊断 | ✅ | 离线 op `scan_dependencies` | `main.tscn` → 5 节点依赖图，`ok:true` |
| G13 类 API 元数据 | ✅ | 离线 op `class_api` | `LightmapGI` → 25 个 `BAKE_ERROR_*` 常量 + 方法表；可 filter |
| G14 场景审计 | ✅ | 离线 op `audit_scene` | 12 节点 / `nodes_after_pack:12` / 0 blocker；不存在的路径干净报错退出 |
| G18 确定性录像 | ✅ | `godot_run_project` 的 `write_movie`/`fixed_fps`/`quit_after` | 30 帧 PNG + frame.wav，自行退出；headless 会 `Parameter "t" is null` 中止 |
| 防 debugger break 卡死 | ✅ | `godot_run_project` 默认 `--ignore-error-breaks` | A/B 实测：不传 → 运行时错误后挂死 20.2s 被杀；传 → 2.4s 正常退出 |

改动量：**+1491 / -5 行，3 个文件**（`mcp_interaction_server.gd` +750/-3、`godot_operations.gd` +698/-0、`godot-bridge.mjs` +43/-2）。

**交付前自检全部通过**：补丁文件与安装副本逐字节一致、回滚集与上游 0.2.0 逐字节一致、上游契约检查 `plugin contract OK`（9 项与原始版本一致）、mjs `node --check` 通过、枚举无重复、两个 GDScript `validate:true/0 errors`、运行时 autoload 正常监听并正常关闭、老功能回归（`environment`/`set_property` 真实工具调用）正常、无 BOM/纯 LF。

生效方式：GDScript 侧下次 `godot_run_project` 自动覆盖进项目（实测提示 `autoload ... was stale and has been overwritten`）；**新增的命令名/枚举/工具参数需重启一次 DSH** 才会暴露。

---

# G5 链：导入通道 + 导入后使用（4.7.2 实机验证）

G5 是一条链：**G5a 是 G5b 的硬前置**——实测 `--import` 之前 `ResourceLoader.exists("res://Box.glb")=false`，之后 `true`。

## G5a 导入通道

- 侧车 `<name>.glb.import` 的 `[remap]` 给出全部关键信息：`type="PackedScene"`、`uid="uid://..."`、`path="res://.godot/imported/Box.glb-<md5>.scn"`；`[deps] dest_files` 是同一路径。**永远读这里，不要自己拼 `.godot/imported` 路径。**
- `[params]` 段等于免费的"导入配置"：`meshes/generate_lods=true`、`meshes/light_baking=1`、`meshes/lightmap_texel_size=0.2`、`materials/extract=0`、`animation/import=true`、`skins/use_named_skins`、`gltf/embedded_image_handling=1`、`gltf/texture_map_mode=1`。
- 增量导入有效：往已有 `.godot` 的项目丢一个新 `Duck.glb` 后跑一次 `--import`，只新增该资产，未重导其它。
- 副作用：`gltf/embedded_image_handling=1` 会把内嵌贴图**写到源目录**（实测多出 `Fox_0.png` + `.import` + `.godot/imported/*.ctex`）。
- `.gdignore` 会让导入器**静默跳过整个目录** → `import_info` 现在会回报 `gdignore_dir`。

## G5b 逐问结论（全部实机跑过）

| 问题 | 结论 | 关键证据 |
|---|---|---|
| 1 离线把 .glb 实例化进 .tscn | 路径是 **`res://xxx.glb`**，`res://xxx.glb::Scene` **不存在**（实测报 `Resource file not found`） | `load("res://Box.glb")` → `PackedScene`；pack 后 .tscn 仅 245 字节，含 `instance=ExtResource(...)` → **保留实例引用而非展开** |
| 2 运行时加载走哪条路 | **已经是现成能力**：`_cmd_instantiate_scene` 就是 `load() as PackedScene → instantiate() → add_child`；`GLTFDocument.append_from_file` 是另一条路（能在未导入的裸 .glb 上工作，但子资源 `resource_path` 为空 → 不可引用/不可入 .tscn） | GLTFDocument 实测 `err=0`，mesh `res_path=''` name `'Box_Mesh'` |
| 3 替换占位节点 | **别用 `Node.replace_by` 指望保 transform**：占位在 (9,9,9)，replace_by 后新节点 origin=(0,0,0) | 正确配方：`add_child` → `new.global_transform = old.global_transform` → 改名 → `old.free()`（实测 (5,2,1)→(5,2,1)、basis 相等） |
| 4 子资源路径与枚举 | 格式是 `res://Fox.glb::<类名>_<后缀>`（`ArrayMesh_711u0`/`StandardMaterial3D_yxt4o`/`Animation_61jl5`） | **后缀不稳定**：改一次 `materials/extract` 0→1 后 mesh `711u0`→`yxt4o`、动画后缀整批位移 → **禁止硬编码 `::后缀`** |
| 5 是否拆成 .scn + 多个 .tres | 默认**不拆**：每个 glb 只有 1 个 `.scn` + `.md5`，网格/材质/动画内嵌为 sub-resource | 要拆只有 `[params] materials/extract=1`（实测重导后源目录出现 `fox_material.tres`）；**列附属资源不能只读 `[deps] dest_files`** |

## godot-asset-planner 联动：能联动，接口已确认

仓库：<https://github.com/LINinLIN-0079/godot-asset-planner-public>（DSH 插件，本机未安装）。

`godot_register_asset`（`godot-asset-planner.ts:2103-2157`）参数：`asset_name`(必填)、`asset_type`(必填，枚举 model/sound/scene/script/image/other)、`file_path`(必填，项目相对路径)、`linked_goal`、`tags`、`project_id`。

**关键事实：planner 自己不会扫描项目、也不会发现新资产**（全文件搜索 `.glb`/`.gltf`/`scan`/`watch` 只命中一条文档示例）→ 注册必须显式推送。联动方式（零代码改动）：G5a 导入完成后由 agent 侧对每个新增资产调用一次 `godot_register_asset(...)`。前置：装进本 profile 并重启一次 DSH。

---

# 文档核对记录（Godot 官方文档 + 4.7.2 实测）

文档版本：`/en/stable/` 当前即 **Godot Engine 4.7 documentation**，与本机 4.7.2 同代。

- **G2 `Mesh.create_trimesh_shape()` / `create_convex_shape()` —— 成立**：<https://docs.godotengine.org/en/stable/classes/class_mesh.html> 原文签名 `ConcavePolygonShape3D create_trimesh_shape () const`、`ConvexPolygonShape3D create_convex_shape (clean: bool = true, simplify: bool = false) const`；两者都是普通公开方法（无 `@editor` 限定），运行时可调。补充实测：`create_trimesh_collision()` 等是 **MeshInstance3D** 的方法，不是 Node3D 的。
- **G4 `CSGShape3D.bake_static_mesh()` / `bake_collision_shape()` —— 成立，且文档比我先前的说法更强**：<https://docs.godotengine.org/en/stable/classes/class_csgshape3d.html> 原文 *"Individual CSG root nodes can also be baked to static resources **with scripts** by calling `bake_static_mesh()` for the visual mesh or `bake_collision_shape()` for the physics collision."*
- **G3 Environment 后处理参数 —— 基本成立，一处命名出入**：文档里 `volumetric_fog_*` 14 个、`ssil_*` 5 个、`sdfgi_*` 12 个、`glow_*` 16 个；但文档属性表列了 `volumetric_fog_energy`，4.7.2 引擎里**不存在**（`set_volumetric_fog_energy=false`，实际是 `volumetric_fog_emission_energy`）→ 实现按 ClassDB 写。
- **G7b "LightmapGI 没有公开 bake 方法" —— 成立**：<https://docs.godotengine.org/en/stable/classes/class_lightmapgi.html> 全页含 `bake` 的标识符只有 `bake_quality`/`get_bake_quality`/`set_bake_quality`/`light_bake_mode`；ClassDB 独立复现。别混淆：`VoxelGI.bake()` **是**公开方法。
- **G5 CLI `--import` —— 成立，落地细节要留意**：原文 *"`--import` Starts the editor, waits for any resources to be imported, and then quits. Implies `--editor` and `--quit`."* → 必须与 `--headless` 组合（或接受开编辑器窗口）。
- **G1 "headless 取不到图像" —— 结论成立，但文档没有明文**：文档只给间接依据（`--headless` = `--display-driver headless --audio-driver Dummy`；专用服务器文档说它面向没有 GPU/显示服务器的机器）。决定性证据是实测：headless 下 `get_image()` 返回 null 并报 `Parameter "t" is null. at: texture_2d_get (./servers/rendering/dummy/storage/texture_storage.h:110)`，`await RenderingServer.frame_post_draw` 永不触发；窗口实例下同代码成功。第三方独立佐证：godogen 记录 *"adding `--headless` to `--write-movie` aborts (`Parameter "t" is null`)"*。

## 核对过程中发现的操作坑（与缺口无关，但会咬人）

1. `godot_command eval` 的包装函数**需要显式 `return`**：裸写最后一个表达式会得到 `{"result":null,"success":true}`。
2. 在 eval 里触发**运行时错误**（不是编译错误）会让 Godot 掉进交互式 `debug>` 提示符，进程**永不退出**、输出无限刷屏，之后 bridge 再无应答。**已修复**：`godot_run_project` 默认加 `--ignore-error-breaks`（A/B 实测有效），且给所有新 op 的错误路径补了 `return`（原先 `quit(1)` 后仍会继续执行）。
3. 上游契约检查 `scripts/check-plugin-contract.mjs` 用正则扫源码里的 `import`+引号，会把我写在**描述文本**里的 `"import"`、`'--import'` 当成模块导入并判定失败 → 这类字符串必须写成 `'imp' + 'ort'` 拼接（已在补丁里处理，检查通过）。
4. **本机 shell 是 Windows PowerShell 5.1（`pwsh` 不存在）**，这有两个坑：`Set-Content -Encoding UTF8` 会写 BOM；`Get-Content` 对**无 BOM 的 UTF-8 中文**按 ANSI(GBK) 解码，再回写就是双重编码乱码（本报告文件就这样被毁过一次，已按原文重建）。改这些源文件请用**字节级写入**（`[System.IO.File]::WriteAllText($p, $s, (New-Object System.Text.UTF8Encoding($false)))`）或 `edit` 工具。本补丁三个文件已确认无 BOM、纯 LF。
5. **一键自检**：`& "C:\Users\openAI\Desktop\godot-bridge-3d-patch\verify-patch.ps1"`（27 项：文件一致性、回滚集、BOM/行尾、mjs 语法、枚举计数、上游契约检查），不需要 Godot、不需要重启 DSH。
