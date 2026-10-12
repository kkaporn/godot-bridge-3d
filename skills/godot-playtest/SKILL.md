---
name: godot-playtest
description: "试玩和调试运行中的 Godot 游戏：截图看画面、模拟按键和点击、读错误日志、采样性能。当需要确认'游戏到底动了没有'、排查运行时错误、优化帧率、或验证一个功能是否真的工作（而不只是代码写完了）时使用。"
user-invocable: true
allowed-tools: godot_run_project, godot_stop_project, godot_get_debug_output, godot_ping, godot_command, godot_screenshot, godot_run_headless, godot_headless_op, godot_validate_script
---

# 试玩与调试 Godot 游戏

**验证的唯一标准是"看到它发生"，不是"代码写完了"。** 本技能给出看到它的方法。

## 标准开发循环

```
改一处  →  启动  →  操作  →  截图  →  读日志  →  改下一处
```

每次只改一处。改完必须验证，不验证的改动等于没做。

## 启动

```
godot_run_project                  # 默认启动当前工作区的项目
```

返回值里几个关键字段：

- `external: true` → 游戏已经在跑（可能是你自己在编辑器里启的），插件接管了它，**不要再去启动一个**
- `port` → 实际用的端口，不是 9090 时要记住
- `game_ready: false` → 引擎起来了但 9090 没应答，看 `godot_get_debug_output` 找原因

**不要用 pwsh/bash 启动 Godot。** 文件沙箱会拦截它写 `user://`，进程直接段错误（signal 11）。只有 `godot_run_project` 走的是不受沙箱约束的子进程服务。

## 看画面

```
godot_screenshot
```

返回 `{ success, width, height, data }`，`data` 是 base64 PNG。**拿到就解码看**，别只看 `success: true` 就认为画面是对的——它可能是一张纯黑或纯色的图。

**`screenshot` 会返回缓存。** 换了场景、改了相机、停掉重启之后，它可能给出上一帧甚至上一次运行的画面，而 `get_scene_tree` 显示的却是新场景。

**判断是否缓存：连续截两次，base64 是否逐字节相同。** 相同就是缓存了，换下面的写法：

```
godot_command eval { "code": "await get_tree().create_timer(0.4).timeout
var img = get_viewport().get_texture().get_image()
return img.save_png('res://shot.png')" }
```

存到 `res://` 再用 read_image 打开。`await` 那句不能省——不等到渲染帧完成，拿到的是空缓冲。

**看到黑屏时依次查：**

1. `godot_command get_scene_tree` → 当前场景对不对？节点树有东西吗？
2. `godot_command get_property {node_path, property: "visible"}` → Camera 或根节点是不是不可见
3. **用数学判断相机朝向，不要靠猜。** 3D 黑屏最常见的原因不是节点缺失，是相机背对着主体：

   ```
   godot_command eval { "code": "var cam = ...; var fwd = -cam.global_transform.basis.z
   var to = (mesh_centre - cam.global_position).normalized()
   return rad_to_deg(acos(clamp(fwd.dot(to), -1, 1)))" }
   ```

   返回 163° 就是背对着。`Camera3D` 看向自己的**局部 -Z**，放在主体一侧时 yaw 必须 180。**别手填欧拉角**，用 `cam.look_at(target)` 或 `look_at_from_position(pos, target, up)` 自动算——手填 `-8, 180, 0` 还会因欧拉顺序把 yaw 带偏 6.8°。
4. `godot_command get_camera` → 看看当前生效的摄像机是谁

## 操作游戏

```
godot_command key_press    { "key": "Space" }
godot_command key_press    { "action": "move_right" }
godot_command key_hold     { "key": "D" }        # 按住不放
godot_command key_release  { "key": "D" }        # 再松开
godot_command click        { "x": 576, "y": 300 }
godot_command mouse_move   { "x": 400, "y": 200 }
godot_command wait         { "frames": 30 }      # 等 30 帧
```

**`key_press` 是瞬间按下再抬起**（内部 `await` 一帧后自动发抬起事件）。要让角色持续朝一个方向走，必须配对使用：

```
godot_command key_hold    { "key": "D" }
godot_command wait        { "frames": 120 }
godot_command screenshot
godot_command key_release { "key": "D" }
```

忘了 `key_release` 会让那个键一直处于按下状态，后续所有截图都带着这个方向的移动。

**按动作名还是按键名？** 两者都支持。游戏代码里读的是**动作**（`Input.is_action_pressed("move_right")`），所以测试游戏逻辑时用 `action` 更贴近真实：

```
godot_command key_press { "action": "move_right" }
```

`action` 形式走 `Input.action_press()`，直接驱动游戏的动作状态；`key` 形式模拟物理按键，需要项目里真的注册了对应映射。

按键名用 Godot 的键名（`Space` `Enter` `Escape` `W` `D` `Up` `Down` `Left` `Right` `Shift` `F1`…）。

## 读错误

```
godot_get_debug_output
```

**增量读取**——每次只返回上次之后的新内容，所以要连续读，反复调用同一次不会重复返回旧的。

关键行：

| 输出 | 含义 |
|---|---|
| `SCRIPT ERROR: ... at: <文件>:<行>` | 脚本运行时错误，有准确位置 |
| `Parse Error: ...` | 编译失败，脚本根本没加载 |
| `Failed to load script` | 依赖的脚本编译不过，或路径错 |
| `Invalid call. Nonexistent function` | 调用了不存在的方法，通常是节点类型不对 |
| `Trying to access array of type ... with invalid index` | 数组越界 |

**改代码前先读完完整堆栈。** 报错第一行是症状，往下几行才是位置。

## 验证一个功能真的工作

验证一个功能真的工作，不要只看代码存在。**构造一个能触发的输入，然后看结果：**

```
# 1. 确认节点在，记下真实路径
godot_command get_scene_tree

# 2. 确认属性当前值
godot_command get_property { node_path: "/root/Main/Player", property: "position" }

# 3. 触发（游戏读的是动作，优先用 action）
godot_command key_press { action: "jump" }
godot_command wait { frames: 10 }

# 4. 再看属性变没变
godot_command get_property { node_path: "/root/Main/Player", property: "position" }

# 5. 截图确认肉眼可见
godot_screenshot
```

属性变了 = 逻辑生效。属性没变 = 信号没连上、输入动作没注册，或者节点路径不对。

## 无头跑逻辑（不启动窗口）

调纯逻辑（伤害计算、状态机、存档读写）时不需要开窗口，快得多：

```
godot_run_headless { quit_after: 300 }                  # 跑 300 帧然后停
godot_run_headless { script: "tests/test_damage.gd" }  # 跑一个测试脚本
```

**必须给 `quit_after` 或让脚本自己调 `get_tree().quit()`**，否则无头场景会无限循环直到超时被杀。

测试脚本模板（用 `assert`）：

```gdscript
extends SceneTree

func _initialize() -> void:
    # 逻辑被测对象
    var damage := 30
    var hp := 100

    assert(damage < hp)                      # 通过
    assert(hp - damage == 70)                # 通过

    print("all assertions passed")
    quit(0)
```

写测试脚本时用 `_initialize()` 而不是 `_init()`：前者运行在 autoload 挂载之后，能正确识别全局单例。

## 性能采样

```
godot_command get_performance
```

返回帧率、绘制调用、节点数等（字段名就是返回的键）。看这几个：

- `fps` 持续低于 30 → 有性能问题，先看节点数是不是失控
- `render_total_draw_calls` 上千 → 2D 项目通常是阴影/粒子/精灵太多
- `object_node_count` 持续增长 → 对象在泄漏，检查有没有忘记 `queue_free()`
- `object_orphan_node_count` 大于 0 → 有节点被创建后没挂进场景树

## 卡住了怎么办

游戏卡在断点上不动（debug 模式遇到脚本错误会暂停等交互）：

```
godot_stop_project     # 停掉
# 改掉编译错误
godot_run_project      # 重启
```

**不要试图在暂停状态下继续。** 直接重启更快。

## 常见现象对照

| 现象 | 检查 |
|---|---|
| 截图是黑屏 | `godot_command get_camera` 看摄像机是否存在且为 current；根节点 visible |
| 按键没反应 | 输入动作是否注册（`godot_manage_input_map`）；用 `action` 名而不是按键名试试 |
| `key_hold` 之后角色一直往一个方向走 | 忘了 `godot_command key_release` |
| 改了脚本运行时没变 | 停止后重启；确认脚本已保存 |
| 场景改了运行时是旧的 | `.tscn` 是否保存（`godot_headless_op save_scene`） |
| 游戏自己退出了 | 读 `godot_get_debug_output` 最后 30 行，通常是段错误或脚本致命错误 |
| `9090` 连不上 | 项目缺 `McpInteractionServer` autoload；`godot_run_project` 会自动装 |
| `godot_run_headless` 卡到超时 | 没给 `quit_after`，脚本也没调 `get_tree().quit()` |
| 截图黑屏但场景树完全正常 | 相机背对着主体，用上面的角度公式算，别靠猜 |
| 两次 `screenshot` 返回一模一样 | 缓存了，改用 `eval` + `save_png` |
| 画面全黑、节点都在、材质也正常 | 查相机 `current` 是否为 true，以及是不是在模型背后 |
| 顶点整体偏移、静止姿态下也在动 | bind 矩阵或骨骼 rest 的空间搞错了，见 `godot-gdscript` 规则 18–20 |
| 蒙皮表面出现收缩 | 权重和 ≠ 1，必须归一化 |

## 3D：先算再看

截图只能确认画面，**验证靠数字**。相机朝向、物体尺寸、角度关系，这些都能算出来就不该靠眼睛：

```
godot_run_headless { script: "scripts/xxx_check.gd" }
```

脚本里 `extends SceneTree`，在 `_initialize()` 里把每个判断写成数字，最后 `quit(0)`（成功）或 `quit(1)`（失败）。**最后那句 `quit()` 不能省**，省了会卡到超时被杀。

参考实现：`rig_check.gd` 的 8 项断言 —— 相机夹角、权重和、bind 精度，全部是可计算条件，没有一条靠审美。
