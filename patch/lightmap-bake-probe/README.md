# LightmapGI 烘焙自动化实测报告（Godot 4.7.2）

结论先说：**那份社区 EditorScript 的思路在 4.7.2 上一半可行、一半不可行 —— 它引用的三个 API 全都不存在；但它想做的事（拿到"烘焙光照贴图"按钮并触发）能用另一条路做到：我确实把 `LightmapGIEditorPlugin._bake()` 调起来了，然而烘出来是 0 张光照贴图。** 所以：**不要把它做成产品功能，把烘焙留成"人工点一下"，自动化只做到烘焙前的体检。**

## 一、那份脚本的三处硬伤（ClassDB 实测，非推测）

| 脚本里的写法 | 4.7.2 实测 | 正确写法 |
|---|---|---|
| `EditorInterface.get_singleton()` | **不存在**（`class_has_method=false`） | `EditorInterface` 本身就是单例，直接当静态对象用 |
| `EditorInterface.select_node(node)` | **不存在** | `EditorInterface.get_selection()` → `add_node()/clear()` |
| `EditorInterface.get_editor_plugins()` | **不存在** | 要么遍历控件树，要么从信号的连接里取对象（见下文） |
| `p.has_method("_get_bake_button")` | `LightmapGIEditorPlugin` 的方法表里**没有** `_get_bake_button`（只有 `_bake`） | 直接 `call("_bake")` 或按下按钮 |
| `EditorScript.get_scene()` | 存在 ✔ | 可用 |

另外 `LightmapGIEditorPlugin` / `EditorNode` **不在 ClassDB 里**（`class_exists=false`）——引擎内部的编辑器插件类根本不暴露给脚本，"按类名找插件"这条路在 GDScript 层面不可达。

## 二、但核心思路可以走通：两条替代路径（都已实测）

1. **从按钮的连接里掏对象**（最巧的一条，完全绕开 `get_editor_plugins`）：
```gdscript
var conns = bake_button.pressed.get_connections()
var cb = conns[0]["callable"]
print(cb.get_object().get_class())   # -> LightmapGIEditorPlugin
print(cb.get_method())               # -> _bake
cb.call()                            # 直接调内部方法
```
实测输出：`{ "object_class": "LightmapGIEditorPlugin", "method": "_bake", "valid": true }`

2. **按文字找按钮**（编辑器是中文界面，按钮文字是 `烘焙光照贴图`）：
```gdscript
EditorInterface.get_base_control()   # -> @Panel@14，控件树可达（实测扫到 954 个 Button）
# 遍历找 text 含 "光照" 且含 "烘焙" 的 Button
target.emit_signal("pressed")
```
实测：`LMPROBE6_button=烘焙光照贴图 visible=true disabled=false`。（注意：**必须先选中 LightmapGI 节点**，否则这个按钮在 3D 界面里压根不存在 —— 我第一次先扫描后选中，扫不到。）

## 三、致命的第三半：调起来 ≠ 烘出来

6 轮变体的结果完全一致：`_bake()` 打印 `Done baking lightmaps in 00:00:00.00.`，然后

```
LMPROBE6_poll frames=1500 has_light_data=true textures=0
LMPROBE6_NO_BAKE frames=1500
```

试过的组合（全部无效）：① 只按按钮；② 只 `call("_bake")`；③ 先 `EditorInterface.get_selection().add_node(lgi)`；④ 把主界面强制切到 3D（`set_main_screen_editor("3D")`）；⑤ 预置 `LightmapGIData` 再烘；⑥ 调 `_edit()`/`_handles()` 钩子驱动插件状态。

**根因**：`_bake()` 的几何收集受插件里**脚本不可见的 C++ 成员状态**支配（`get_property_list()` 只返回两个类别项，`get()/set()` 读写不到那些字段），而这个状态只由编辑器自己的 UI 交互建立。所以"纯脚本驱动烘焙"在 4.7.2 上不可靠。

顺带排除的非问题：UV2 是有的（`.tscn` 里每个 ArrayMesh 都写了 `lightmap_size_hint`，说明 `lightmap_unwrap` 成功）、`gi_mode` 默认就是 STATIC（所以没写进 .tscn）、灯是 `light_bake_mode = 1`、LightmapGI 是场景根的直接子节点、选中态在按下按钮的那一刻是在的。

## 四、官方文档怎么说（注意它本来就是"人工动作"）

<https://docs.godotengine.org/en/stable/tutorials/3d/global_illumination/using_lightmap_gi.html>：

> "To begin the bake process, click the **Bake Lightmaps** button at the top of the 3D editor viewport **when selecting the LightmapGI node**"

## 五、可落地的替代方案（按推荐度）

1. **✅ 推荐：人工点一下 + 脚本做体检**。用已经落地的 `unwrap_lightmap_uv2`（本补丁）保证每个网格有 UV2，再用一个新的只读命令 `lightmap_check` 把烘焙前的坑全排掉（每个 MeshInstance3D 是否有 UV2 / `gi_mode` 是否 STATIC / LightmapGI 是否是场景根直接子节点 / 灯的 `light_bake_mode` / 是否存在已有 `light_data`），然后人选中 LightmapGI 点一次「烘焙光照贴图」。零脆弱、成本一次点击。
2. **VoxelGI / SDFGI 路线**：`VoxelGI.bake(from_node, create_visual_debug)` 是**公开方法**，文档里没有任何 editor-only 限制（ClassDB 也确认存在）；`Environment.sdfgi_*` 12 个参数已在本次补丁里补齐。完全可脚本化，代价是显存/体素分辨率、视觉风格与光照贴图不同。（**尚未实测**，需要窗口实例 + GPU；你说一声我就验。）
3. **自带工具栏按钮**（gigabake 模式）：`add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, btn)` 同版本可用（gigabake / csg_converter 就是这么干的），但按钮回调最终仍要落到第 2 节的模拟点击 → 不解决根本问题，只是让人少找按钮。
4. **外部烘焙**：Blender/Bakery 烘好贴图再导入，用自定义 shader 混进 albedo（不是 Godot 真 GI）。`LightmapGIData.set_lightmap_textures()` 是公开的，但每个实例的 UV 变换由 Godot 内部生成，手工回填不完整 → 不推荐。
5. **接受它不是自动化项**：Godot 官方就是把烘焙设计成编辑器里的手动步骤，自动化到"条件检查 + 报告"为止。

## 六、复现方式

本目录是可复现的完整实验：

- `addons/lm_probe/plugin.gd` —— 探针（v6：切 3D 界面 → 开场景 → 选中 LightmapGI → 按文字找按钮 → 同时从信号连接取 `LightmapGIEditorPlugin` 并直接 `_bake()` → 轮询 1500 帧）
- `run_editor.gd` —— 启动**真实编辑器**（窗口模式，GPU 可用）并回传 stdout：`OS.execute(godot, ["--editor","--path",proj,"--quit-after","9000"])`
- `make_scene.gd` —— 生成 `lm.tscn`（5 个网格 + `lightmap_unwrap` 出 UV2 + 静态平行光 + LightmapGI 作为场景根直接子节点）
- `lm.tscn` —— 生成好的测试场景
- `editor-run.log` —— 最后一次编辑器运行的输出

跑法：把本目录内容放进一个 Godot 4.7.2 项目根，`project.godot` 的 `[editor_plugins] enabled` 指向 `res://addons/lm_probe/plugin.cfg`，然后
`godot --headless --path <proj> --script res://run_editor.gd`。
