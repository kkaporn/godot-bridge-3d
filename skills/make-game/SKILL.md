---
name: make-game
description: "从零做一个 Godot 游戏：把'我想做 XX 游戏'变成可运行、可验证、能打包的完整项目。当用户说想做一个游戏、不知道从哪开始、游戏做了一半、或问怎么让游戏跑起来时使用。覆盖完整流程：定玩法 → 建最小可玩场景 → 逐层加机制 → 每步验证 → 导出发布。"
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, AskUserQuestion, godot_create_project, godot_run_project, godot_stop_project, godot_get_debug_output, godot_ping, godot_command, godot_screenshot, godot_headless_op, godot_create_script, godot_validate_script, godot_set_project_setting, godot_manage_autoloads, godot_manage_input_map, godot_manage_export_presets, godot_export_project, godot_run_headless
---

# 从零做一个 Godot 游戏

核心原则：**永远先让一个东西动起来，再往上加。** 不要先设计完整架构再动手——先做出一块能跳的平台，比写十页设计文档有用。

## 阶段 0：确认引擎可用

动手前先确认工具链通。这只花一次调用，但能避免后面所有步骤失败。

```
godot_ping
```

- 返回 `game_running: false` 是正常的（还没启动游戏）。看有没有 `plugin_version` 和引擎路径提示。
- 如果任何 `godot_*` 工具报 **"no Godot engine path configured"** 或找不到引擎：
  **停下来问用户** Godot 4.x 可执行文件在哪（`Godot_v4.x-stable_win64.exe`），拿到后调 `godot_set_engine_path` 存好。
  **不要自己在文件系统里搜 Godot，也不要去下载。**

## 阶段 1：把想法压成一页纸

用户通常只给一句话（"我想做一个躲避障碍的小游戏"）。**不要立刻写代码。** 先问三个问题，一次问完：

1. **核心动作是什么？** 玩家每秒重复做的那件事（跳 / 射 / 躲 / 放置 / 合并）。
2. **失败条件是什么？** 什么时候算输。
3. **2D 还是 3D？** 不确定就默认 2D——2D 从零到可玩快得多，视觉也更好控制。

拿到答案后，用一段话复述理解，**让用户确认或纠正**：

> 我理解的是：一个 2D 小游戏，玩家控制方块上下左右移动躲开下落的障碍，被碰到就结束，存活时间就是分数。这个对吗？

确认后再动手。用户纠正你是省钱，不是返工。

**不做的**：不做长篇设计文档，不列功能清单让用户勾选。用户要的是游戏，不是规划。

## 阶段 2：最小可玩版本（最重要的一步）

**只做一个"能证明这条路通"的场景。** 判断标准：游戏能启动、能操作、能看见结果。

以"躲避下落障碍"为例，一步步来，每步之间不要跳：

```
godot_create_project              # 建空项目
godot_manage_input_map            # 注册 move_left/move_right/move_up/move_down
godot_headless_op create_scene    # 建 res://scenes/main.tscn
godot_headless_op add_node        # Player / ObstacleSpawner / UI
godot_headless_op attach_script   # 挂 player.gd
godot_create_script scripts/player.gd   # 写移动逻辑
godot_validate_script scripts/player.gd # 编译检查
godot_run_project                 # 启动
godot_command key_press           # 按方向键
godot_screenshot                  # 截图确认真的动了
```

**做完立刻截图给用户看。** 第一次看到自己的东西动起来，是整个流程里最重要的反馈点。

如果这一步跑不通，后面全都白搭。所以：

- 玩家能响应按键 → 截图
- 障碍能生成并下落 → 截图
- 碰到会结束 → 不用截图，文字说明就行

三样都成立，这个游戏"活着"。**这时候再告诉用户"基础跑通了，接下来加 XX"**，让用户决定要不要继续。

## 阶段 3：逐层加，每层都验证

一次只加**一个**机制。加完立刻验证，通过了再下一个。

推荐顺序（从影响最大的开始，早点看到效果）：

| 层 | 内容 | 验证方式 |
|---|---|---|
| 1 | 核心动作能玩 | key_press + 截图 |
| 2 | 有输赢条件 | 触发失败条件，看是否结束 |
| 3 | 有反馈（音效/粒子/闪白） | 截图 + 听音效反馈 |
| 4 | 有分数/进度 | get_ui_elements 看 UI |
| 5 | 有开始/结束界面 | change_scene 切换 |
| 6 | 美术音效素材 | 导入后截图确认 |
| 7 | 设置项、存档 | 重启验证 |

**每层的验证不许跳。** 上一层没过就往下堆，两个 bug 叠在一起会花三倍时间。

## 硬规则

这些是从反复失败里总结的，违反它们会浪费时间：

1. **改了必验。** 每次改动后至少一次 `godot_screenshot` 或 `godot_get_debug_output`。不验证的改动等于没做。

2. **可计算的绝不靠眼睛判断。** 比例、角度、方向、偏移量、噪声强度、蒙皮权重——凡是能写成数字的，先写成断言跑 `godot_run_headless --script res://scripts/xxx_check.gd`，通过了再看截图。

   **截图只用来确认，不用来验证。** 眼睛看不出 16.8° 的坡度太平，也看不出相机背对着主体画面全黑。

   真实案例：一个地形原型在"看起来不够立体"上卡了三轮，每轮都在凭感觉调参数。第四轮才发现是**96 宽只有 29 高**的宽高比问题——写成断言，一行算完。同期还靠断言抓到相机朝向反了 180°、噪声振幅超过特征尺寸导致地形撕裂。

   判断标准：**如果一个数字算错了画面会错，就算。** 但造型偏好（这个角色圆一点还是方一点）不是数学问题，别伪装成断言，也别拿"审美"当算错的借口。

3. **几何/物理/动画的问题先算再看。** 骨骼朝向、蒙皮权重、碰撞体大小、相机位置这类，源码里能查的就查，别猜：

   ```
   godot_headless_op { "operation": "class_api", "params": { "class_name": "Skeleton3D" } }
   ```

4. **报错先读再改。** 脚本编译失败 → `godot_validate_script` 拿准确的行号；运行时错误 → `godot_get_debug_output` 看完整堆栈。**不要凭猜测改代码。** 看到 `Parser Error: Identifier "xxx" not declared` 就去找这个标识符从哪来，别直接加个变量糊过去。

5. **不批量改。** 一次改一个文件、验证、再改下一个。同时改五个文件，出错时不知道是哪一处引起的。

6. **节点路径要对。** `$Player/Sprite2D` 相对当前节点；`/root/Main/Player` 绝对路径。写错就是 null 引用。用 `godot_command get_scene_tree` 看真实结构，别猜路径。

7. **写完脚本先 validate。** `godot_create_script` 写完立刻 `godot_validate_script`，比启动游戏看报错快十倍。

8. **问用户偏好而不是替用户决定。** 美术风格、颜色、难度、手感这类主观的东西，问一句比猜十轮便宜。

9. **不确定就问，不要静默假设。** 尤其涉及"删掉现有内容"的操作——先说清楚要删什么，得到确认再删。

## 程序化资产：能算出来的都别手摆

用户问"能不能直接生成树/山/角色，不用一个个方块拼"——**能。** 不要因为"看起来像美术活"就说不该程序化。形状、比例、层级、蒙皮全是数学。

| 要什么 | 用什么 |
|---|---|
| 地形、山脉 | `FastNoiseLite`（SIMPLEX/FBM/RIDGED）+ 域扭曲；半径衰减做岛 |
| 体素世界（Minecraft 式） | `GridMap`（56 个方法）+ `MeshLibrary` |
| 有机形体 | `godot_command procedural_mesh` —— **接受任意顶点/法线/UV/索引数组，不限形状** |
| 复合体（建筑/机械） | `CSGShape3D` + `godot_command csg_bake` |
| **角色 + 骨骼 + 蒙皮 + 动画** | 见下，完全可算 |

**角色不需要美术资产。** 线性混合蒙皮（LBS）是 `v' = Σ wᵢ · Bᵢ · v`，四个权重四个矩阵一次求和，没有任何"算不出来"的部分。整套流程：

1. 建 `Skeleton3D`，**rest 写父骨空间的局部变换**（不是世界坐标）
2. 同样显式 `set_bone_pose(i, rest)` —— Godot 4 的 pose 默认是 identity，渲染器用 pose 不是 rest
3. 生成网格（每根骨骼一个渐细的管子），写入 `Mesh.ARRAY_BONES` / `Mesh.ARRAY_WEIGHTS`
4. 权重按到骨骼**线段**的距离算，不是到骨头原点；关节处父/子各占一半
5. 权重和必须 **恰好为 1**，否则表面会向原点收缩
6. `Skin.add_bind(i, global_rest.affine_inverse())` —— bind 用**全局** rest 的逆，且 `get_bind_pose()` 取出来**不要再取逆**
7. 动画写成 `角度 = 基准 + 振幅 · sin(相位)`，各肢体给不同相位偏移

写完跑一个断言脚本，至少验证这四项：**权重和为 1、LBS 在静止姿态位移为 0、每个关节有双骨骼共享顶点、bind × 全局rest = 单位矩阵**。这四条过了，蒙皮就是对的。

> **完整可运行实现（已验证，8 项断言全过）**：`examples/procedural_rig.gd`（20 骨骼、1330 顶点、2280 三角面）+ `examples/rig_check.gd`（验证脚本）。拷进项目直接 `godot_run_headless --script` 就能跑。

## 别手工一条条试，写冒烟脚本

你的游戏一旦有多个可被外部调用的东西（交互服务器命令、自己写的 RPC、存档接口），**不要靠手工点**。手工点几十下必漏，而且会把「慢」误判成「坏」。

`examples/service_smoke.gd` 是可复用骨架：改 `TARGETS` 就能测你自己的接口。结果分三档：

| 判定 | 含义 | 要不要修 |
|---|---|---|
| PASS | 正常返回 | 否 |
| PARAM | 调用方给错了目标或参数，被测对象是活的 | 否（改你的调用） |
| BUG | 内部崩了、或卡死没响应 | **是** |

两个必须遵守的细节，否则会得到一堆假缺陷：

1. **socket 超时要大于被测命令自身的超时。** 一个默认 30 秒的命令配 8 秒超时，必然误报成死锁。
2. **一个目标把服务打死之后，后面全部会失败。** 每次失败后再发一条必定成功的命令探活，才能区分「这一个坏了」和「服务已经挂了」。探活要重试一次并留间隔 —— 上千次快速连接有 TCP 抖动，一次失败就判死同样满屏假阳性。

这条方法实测在 116 条命令上抓到过 4 个真缺陷，而手测前 20 条时一个都没发现。

### 还要灌错参数 —— 真正的坑都在错误路径上

只跑一遍合法调用，测的是 happy path。agent 最容易走到的其实是错误路径（它会把参数拼错），而你手工测永远不会想到去试这些。

做法：每条命令 × 一组恶意载荷（类型全错、缺字段、`null`、超长、负数、`../` 路径）：**判据不是「命令成功」，而是「服务在每条执行完之后都还回答得动」**。

这一轮就是靠它抓到 **删掉 `/root` 会让整个服务器消失**（返回 `success: true`，然后客户端 `ECONNREFUSED`，游戏只能手动重启）—— 正常参数测试永远碰不到这条路。

`examples/classify_check.gd` 验证冒烟脚本的判据本身不是空转 —— **永远绿的测试等于没测**。

### 自己写的接口也要防"自杀"

任何接收节点路径然后删除/搬走的接口，都要拦住场景树根、管理器自己和自己的祖先 —— 否则一次误传就让你失去唯一的恢复手段。写法见 `godot-gdscript` 的「破坏性命令必须有护栏」。

## 阶段 4：导出发布

游戏能玩了、要给别人玩时：

```
godot_set_project_setting          # application/config/name、application/config/version
godot_manage_export_presets       # 建 "Windows Desktop" preset
godot_export_project               # 出 build
```

**Steam 上架**还需要额外几步（这些工具不覆盖）：

- 注册 Steamworks、拿 AppID
- 装 Steamworks SDK 或 GodotSteam 插件做成就/云存档
- SteamPipe depots：`app_build_xxx.vdf` + `depot_build_xxx.vdf`，用 steamcmd 上传
- 商店页素材：胶囊图 616×353、截图 1920×1080、预告片
- 仓库要有 LICENSE 和 attribution.md（社区素材需要署名，缺失有下架风险）

导出前必查：`.gitignore` 排除了 `.godot/`、代码里没有硬编码本机路径、`application/config/version` 已设。

## 常见卡点

| 现象 | 原因 | 处理 |
|---|---|---|
| `godot_run_project` 报找不到引擎 | 没配引擎路径 | 问用户要 exe 路径 → `godot_set_engine_path` |
| 游戏启动了但 9090 连不上 | 项目缺 `McpInteractionServer` autoload | `godot_run_project` 会自动装；若失败看 `godot_get_debug_output` |
| 启动游戏卡在报错断点 | eval 或脚本有编译错误 | `godot_stop_project` → 改 → 重启 |
| 改了脚本游戏里没变化 | 热重载不生效 | 停止再启动，或确认脚本没被缓存 |
| 场景改了但运行时还是旧的 | .tscn 没保存 | `godot_headless_op save_scene` |
| 玩家不动，但代码看着没问题 | 输入动作没注册 | `godot_manage_input_map` 检查；或用了 `ui_left` 之外的未注册动作 |

## 配套技能

- **`godot-gdscript`** —— 写 GDScript 时的类型规范和 API 陷阱。写任何脚本前先看，能避免大部分语法和运行时报错。
- **`godot-playtest`** —— 试玩与调试的完整手法：截图、按键、读日志、性能采样。开发循环中反复用。
