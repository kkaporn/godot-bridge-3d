---
name: godot-gdscript
description: "写 GDScript（Godot 4.x）时的类型规范与 API 陷阱。写任何 .gd 文件前先看：哪些写法在 Godot 4 会编译失败、哪些会在运行时静默出错、信号和节点引用怎么写才不出 null 错误。触发词：写脚本、写 GDScript、脚本报错、Parse Error、Invalid call、signal、@onready、类型推断。"
user-invocable: true
allowed-tools: Read, Write, Edit, godot_create_script, godot_validate_script, godot_command
---

# GDScript（Godot 4.x）避坑指南

以下每一条都对应一类真实报错。先看这里能省掉大部分调试。

## 类型：`Variant` 陷阱

**规则 1：`clamp()` 返回 `Variant`，不能用来推断变量类型。**

```gdscript
# ✗ 错：Godot 默认警告设置下这是错误
var t := clampf(0.2, 0.0, 1.0)     # ← 这个是对的
var t := clamp(value, 0.0, 1.0)     # ✗ clamp 返回 Variant，推断成 Variant 报错

# ✓ 对：必须用 clampf()（float 专用）
var t: float = clampf(value, 0.0, 1.0)
```

同族的还有 `min()` / `max()` / `round()` / `abs()` —— 一律用带后缀的版本：`clampf` `clampi` `mini` `maxi` `minf` `maxf` `absi` `absf` `roundi` `roundf`。

**规则 2：`lerp()` / `smoothstep()` 之类返回 Variant 的，两边都要有类型。**

```gdscript
var pos: Vector2 = start.lerp(end, 0.5)   # 显式标注就行
```

**规则 3：算术结果从 int 变 float 时要显式转换。**

```gdscript
var ratio: float = float(count) / float(total)    # ✓
var ratio: float = count / total                    # ✗ 结果是 int 运算，会截断
```

## 节点引用

**规则 4：`@onready` 用于一切运行时才存在的节点。**

```gdscript
@onready var sprite: Sprite2D = $Sprite2D
@onready var ui: Control = get_tree().get_first_node_in_group("hud")
```

`$Sprite2D` 在 `_init()` 阶段是 `null`，在 `_ready()` 之后才有效。

**规则 5：`%UniqueName` 要求节点在场景里标记 `unique_name_in_owner`。** 没标记会返回 null 且**不报错**——最难查的一类 bug。用 `$Sprite2D` 或 `get_node("Sprite2D")` 更稳。

**规则 6：路径不存在时 `$` 返回 null，之后调方法必然崩。** 写完节点路径后用 `godot_command get_scene_tree` 核对真实结构，别凭记忆写。

```gdscript
# 安全写法
var node := get_node_or_null("Player/Sprite2D")
if node == null:
    push_warning("找不到 Player/Sprite2D")
    return
```

## 信号

**规则 7：`await` 一个永不发出的信号 = 永久卡死。** 调试模式下整个游戏会停住，看起来像崩溃。

```gdscript
await get_tree().create_timer(0.5).timeout   # ✓
await some_signal                            # ✗ 对方不 emit 就死等
```

**规则 8：给可重复触发的事件加超时兜底。**

```gdscript
await some_signal.timeout   # 要对方额外 emit 一个 timeout 才有效
```

**规则 9：自定义信号声明在类顶部，参数不要带类型化容器除非必要。**

```gdscript
signal damaged(amount: float)          # ✓
signal item_picked(id: StringName)     # ✓
```

## 类与实例

**规则 10：抽象基类不能 `new()`。**

```gdscript
StandardMaterial3D.new()      # ✓
BaseMaterial3D.new()          # ✗ BaseMaterial3D 是抽象类，parse error，整份脚本编译失败
Node3D.new()                  # ✓
```

这是最容易整份脚本挂掉的一个错误。

**规则 11：`class_name` 全局类需要在编辑器里被识别。** 纯 headless 环境下引用一个还没被扫描的 `class_name` 会报 "Identifier not found"。用 `godot_run_headless` 或先 `--import` 让引擎扫一遍。

## 动画与补间

**规则 12：用 Tween 不用 `await` + Timer 做重复触发的视觉效果。**

```gdscript
func flash() -> void:
    if _tween and _tween.is_valid():
        _tween.kill()        # 先杀掉在飞的，防止连击时累积
    _tween = create_tween()
    _tween.tween_property(self, "modulate:a", 0.0, 0.08)
    _tween.tween_property(self, "modulate:a", 1.0, 0.12)
```

连击时 `await create_timer()` 无法中途取消，会留下一堆永远不恢复的 Tween。

**规则 13：`create_tween()` 绑定在节点上。** 节点被释放时 Tween 自动失效，所以在 `_process` 里裸调 `create_tween()` 要小心——它会绑到最近的那个节点，不一定是当前节点。用 `get_tree().create_tween()` 显式指定。

## 资源与属性

**规则 14：`AudioServer` 的总线音量是方法不是属性，不能用 Tween 补间。**

```gdscript
# ✓
var tw = create_tween()
tw.tween_method(AudioServer.set_bus_volume_db.bind(idx), from_db, to_db, 0.3)

# ✗ 运行时错误
create_tween().tween_property(AudioServer, "bus_volume_db", -20.0, 0.3)
```

**规则 15：`Material` 是共享资源。** 改一个 mesh 的材质会改掉所有用同一个 `.tres` 的 mesh。要单独改就用 `material_override` 配一个 `.duplicate()`。

## 3D 空间数学（做骨骼/蒙皮/程序化网格前必看）

**规则 16：不确定某个类有什么方法，先查，不要凭记忆。**

```
godot_headless_op { "operation": "class_api", "params": { "class_name": "Skeleton3D", "filter": "bind" } }
```

`filter` 是子串过滤。参数名是 `class_name`，**不是** `class`。这比翻文档快，也不会像本文件早期版本那样把方法记错。

**规则 17：`Skeleton3D` 没有 bind 方法，bind 在 `Skin` 资源上。**

```gdscript
sk.get_bone_rest(i)      # ✓ 在 Skeleton3D 上
sk.get_bone_global_pose(i)  # ✓ 世界空间，含父骨累加
sk.get_bind_pose(i)      # ✗ 不存在！Invalid call
skin.get_bind_pose(i)    # ✓ 在 Skin 上
```

**规则 18：Godot 4 的 rest 和 pose 是两个独立量。** 新建的 `Skeleton3D` 的 pose 是 **identity**，不是它的 rest。`reset_bone_poses()` 在没设置过 pose 时是空操作。渲染器用 **pose** 做蒙皮，所以只设 rest 会让所有顶点在第一帧跳一下。设完 rest 就要显式 `set_bone_pose(i, rest)`。

**规则 19：骨骼 rest 是父骨空间的局部变换，不是世界坐标。** Godot 自己会沿父子链累加。写绝对位置进去 = 每个父骨偏移被算两遍。

**规则 20：LBS 公式里 bind 不要重复取逆。** Godot 的 `Skin.get_bind_pose()` 已经含了逆。

```gdscript
# ✓ 正确：bind 已含逆
var xf := sk.get_bone_global_pose(bi) * skin.get_bind_pose(bi)
# ✗ 错误：逆了两次，等于把偏移平方
var xf := sk.get_bone_global_pose(bi) * skin.get_bind_pose(bi).inverse()
```

同理 bind 要用**全局 rest** 的逆来建：`skin.add_bind(i, global_rest.affine_inverse())`。用局部 rest 会让每个顶点偏一个父骨的位移量。

**规则 21：`SurfaceTool` 没有骨骼权重 API。** 4.7 只有 `set_bones`。蒙皮权重必须直接写进 `ArrayMesh`：

```gdscript
arrays[Mesh.ARRAY_BONES] = PackedInt32Array()    # 每顶点固定 4 个
arrays[Mesh.ARRAY_WEIGHTS] = PackedFloat32Array() # 对应权重，和必须为 1
```

权重不足 4 个时补 `{i: 任意骨骼, w: 0.0}`，但要**按权重降序排完再补**，否则零权重的占位会挤掉真实影响。

## 运行时报错的三种"静默失败"

GDScript 的运行时报错**不会抛出异常给你 catch**，它是"打印一行错误然后中止当前函数、返回 null"。这造成三种很难查的情况：

**一、中止后的代码一行都不执行。** 函数在中间崩掉，后面的 `return`、赋值、信号发射全部跳过。调用方拿到的是 `null`，而不是错误。

**二、`_send_response` 之类的收尾调用被跳过 → 整个服务锁死。** 这是 mcp_interaction_server 里实际发生过的：某条命令参数形状不对，在 `v[0]` 上中止，于是它既不回响应也不释放 busy 标志，之后**每一条**命令都返回 "Server busy"，必须重启游戏才能恢复。

对应做法：任何"收尾必须执行"的地方（回响应、释放锁、清临时节点），不要依赖函数正常走完。用一个哨兵变量：

```gdscript
var _responded := false

func handle(req) -> void:
    _responded = false
    _dispatch(req)                    # 可能中途崩
    if not _responded:                # 崩了 —— 替它收尾
        _send_response({"error": "handler aborted on a script error"})
    _responded = false

func _send_response(d: Dictionary) -> void:
    _responded = true                 # 唯一出口，标记已收尾
    ...
```

**三、类型转换往往不报错，而是静默给默认值。** 这个最危险：

```gdscript
var v: Variant = "not-a-number"
float(v)          # 不报错！得到 0.0
Vector3(v.x, ...) # 不报错！得到 (0,0,0)
"abc".to_int()    # 不报错！得到 0
```

所以"没报错"不等于"值对了"。**关键数值必须断言，不能靠"它没报错"推断它对。**

## 参数形状：同一个字段的两种写法都要收

外部调用（JSON、MCP、配置文件）传向量时，两种形状都会出现：

```json
[1, 2, 3]                    // 数组
{"x":1, "y":2, "z":3}        // 字典
```

同一个插件的不同命令可能各收一种，调用方会混。**写一个转换函数，别在两处各写一遍 `v[0]`：**

```gdscript
func _to_vec3(v: Variant) -> Vector3:
	if v is Array or v is PackedFloat32Array:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("z", 0.0)))
```

只收数组时，传字典会在 `v[0]` 上中止（见上面第二种失败）。

## 抽象类不能实例化

`ClassDB.class_exists()` 为 true 不代表能 `instantiate()`。抽象的基类返回 `null`：

| 抽象类 | 要用这些具体子类 |
|---|---|
| `CSGShape3D` | `CSGBox3D` `CSGSphere3D` `CSGCylinder3D` `CSGTorus3D` `CSGPolygon3D` `CSGMesh3D` `CSGCombiner3D` |
| `Shape3D` | `BoxShape3D` `SphereShape3D` `CapsuleShape3D` `CylinderShape3D` `ConvexPolygonShape3D` |
| `BaseButton` | `Button` `CheckBox` `CheckButton` `OptionButton` |

```gdscript
if not ClassDB.can_instantiate(type_name):     # 用这个判断，不要用 class_exists
    var kids := ClassDB.get_inheriters_from_class(type_name).filter(
        func(k): return ClassDB.can_instantiate(k))
    push_error("'%s' 是抽象类，改用: %s" % [type_name, ", ".join(kids)])
```

## 破坏性命令必须有护栏（一次误传就毁掉整场会话）

任何"接收一个节点路径然后把它删掉/搬走"的接口，都要拦住**会让你自己失去控制权**的目标。

真实案例：`remove_node {node_path: "/root"}` 返回 `{"success": true, "removed": "root"}`，然后整个交互服务器消失（客户端收到 `ECONNREFUSED`），游戏必须手动重启。它删掉了场景树根，连带删掉了作为 autoload 挂在下面的服务器本身 —— **而服务器是唯一能撤销这个错误的手段**。

要拦三类目标：

1. **场景树根** `get_tree().root`
2. **服务器/管理器自己**
3. **自己的任意祖先** —— 删祖先等于删自己

```gdscript
# 返回错误字符串；返回 "" 表示可以安全操作。
func _refuse_server_fatal(node: Node) -> String:
	if node == null:
		return ""
	if node == get_tree().root:
		return "Refusing to touch '%s': it is the scene-tree root." % str(node.get_path())
	if node == self:
		return "Refusing to touch '%s': it is the server itself." % str(node.get_path())
	var walk: Node = self
	while walk != null:
		if walk == node:
			return "Refusing to touch '%s': the server is inside it." % str(node.get_path())
		walk = walk.get_parent()
	return ""
```

在 `remove_node` 和 `reparent_node` 里都调用它。**只查被操作的节点，不要查目标父节点** —— 把节点移到 `/root` 下是最常见的正常用法，拦了等于把功能修死。

哪些接口需要护栏：搜一遍 `.queue_free()` / `.free()` / `.reparent(` / `remove_child(`，逐个问"这里的节点来自用户输入吗"。只来自自己创建的临时节点（HTTPRequest、临时容器、调试网格）就不用管。

**这类问题特别值得专门去测**：它不会在正常使用中暴露 —— 你得主动试"删除根节点"这种看起来没人会这么干的输入。而它一旦发生，整场会话结束且没有恢复手段。

## 常见运行时报错对照

| 报错 | 真正的原因 |
|---|---|
| `Invalid call. Nonexistent function 'xxx' in base 'Nil'` | 路径错了，或 `@onready` 还没执行 |
| `Attempt to call function 'xxx' in base 'null instance'` | 同上 |
| `Parse Error: Identifier "xxx" not declared` | 变量拼错 / class_name 未注册 / 缺 preload |
| `Invalid get index 'xxx' (on base: 'Nil')` | Dictionary 没这个键，且没判空 |
| `Trying to assign value of type 'int' to a variable of type 'String'` | 类型不匹配，`String(x)` 显式转换 |
| `Parse Error: Cannot find member "xxx" in base "Node"` | 节点类型不对，先 `godot_command get_node_info` 确认 |
| `Object has been freed` | 存了节点引用但节点已被 `queue_free()`，改用 `%Name` 或每次重新 `get_node_or_null` |
| `Invalid call. Nonexistent function 'get_bind_pose' in base 'Skeleton3D'` | bind 在 `Skin` 资源上，不在骨架上（规则 17） |
| `Node not inside tree. Use look_at_from_position() instead.` | `look_at()` 需要节点在场景树里；纯数学场景用 `look_at_from_position()` |
| `Out of bounds set index '0' (on base: 'PackedVector3Array')` | Packed 数组要先 `append()` 占位再按下标写，或先 `resize()` |
| `Condition "array_len == 0" is true` → `add_surface_from_arrays` 失败 | 数组全空时也会走到这，检查上游是不是提前 return 了 |
| `String formatting error: unsupported format character` | GDScript 的 `%` **没有 `%e`**，用 `str(x)` |
| `Invalid get index 'x' (on base: 'Dictionary')` | 把字典当数组用了：`v[0]` 而 v 是 `{x,y,z}`。用 `_to_vec3()` 统一收两种形状 |
| `Failed to instantiate: XXX` / `instantiate()` 返回 null | XXX 是抽象基类。先查 `ClassDB.can_instantiate()`，改用具体子类 |
| 命令发出去了但**永远收不到响应** | 处理函数在中间崩了，收尾的 `_send_response` 被跳过 → busy 标志没释放。见「三种静默失败」的哨兵写法 |
| 命令返回 `success: true` 之后**服务直接消失**（客户端 `ECONNREFUSED`） | 它删掉/搬走了自己所在的节点。见「破坏性命令必须有护栏」 |

## 先算，再看

3D 的任何"看起来不对"都应该在截图之前变成断言。把判断写成数字，跑 `godot_run_headless --script res://scripts/xxx_check.gd`，比反复截图快一个数量级，而且能抓到眼睛抓不到的东西。

已经这么抓到过的真实 bug（都不该靠眼睛发现）：

- 蒙皮 bind 逆了两次 → 静止姿态每个顶点偏 3.33 米
- 骨骼 rest 写成世界坐标 → 父骨偏移被算两遍，偏 10.17 米
- 相机 `-Z` 朝向搞反 → 画面全黑，而场景树完全正常
- 噪声域扭曲振幅超过特征尺寸 → 地平线撕成碎片（`振幅 / (1/频率) > 0.35` 时必然发生）
- 地形起伏跨度和宽度不匹配 → 96 宽只有 29 高，坡度 16.8°，一眼看不出来

判断要不要留一条断言的标准：**如果一个数字算错了画面会错，就算。** 造型偏好不是数学问题，不要伪装成断言。

### 同一条规则也适用于"测插件/测工具"

对着一堆命令手工点几十下，和对着截图猜数值一样不可靠 —— 你会漏掉大部分，而且会把"慢"误判成"坏"。

写个脚本自动把每条命令发一遍，**区分三档**：

| 判定 | 含义 |
|---|---|
| PASS | 正常返回 |
| PARAM | 是我参数/目标给错了，命令本身活着 |
| BUG | 命令内部自己崩了、或把服务锁死了 |

这个脚本在 116 条命令上抓到过 4 个真缺陷（一个锁死服务、一个删掉场景根把服务器带死、一个报错误导、一个无视超时），而手测前 20 条时一个都没发现。要点：

- **socket 超时要大于命令自身的超时**。默认 30 秒的命令配 8 秒 socket 超时 → 必然误报"卡死"。
- **一条命令把服务打死之后，后面全都会失败**。要探活（再发一条必定成功的命令）区分"这一个坏了"和"服务挂了"，否则会得到 80 个假的独立缺陷。探活本身要重试一次并留间隔 —— 上千次快速连接会有 TCP 抖动，一次失败就判死同样会造成大量假阳性。
- 判据要区分"节点类型不对"（调用方的锅）和"Invalid call / Out of bounds"（实现方的锅）。不区分的话，参数给错会淹没真缺陷。

### 光测"正常参数"不够，还要灌错参数

只跑一遍最小合法调用，覆盖的是"happy path"。真正难查的缺陷在错误路径上 —— 而那正是 agent 最容易走到的路（它会把参数拼错）。

做法：每条命令 × 一组恶意载荷（类型全错、缺字段、`null`、超长字符串、负数、`../` 路径、非法代码片段）。**判据不是"命令成功"，而是"服务在每条命令之后都还回答得动"**。

```
116 条命令 × 10 组恶意载荷 = 1160 次调用
replies 1160 | slow 0 | WEDGES 0 | server alive after full fuzz: true
```

这一轮正是靠它抓到"删掉 `/root` 让服务器消失"—— 正常参数测试永远不会碰到这条路径，因为没人会想到去删场景根。

## 写完立刻验证

```
godot_validate_script scripts/your_script.gd
```

这个工具比启动游戏看报错快得多，且能拿到准确行号。**每次写完脚本都跑一次**——不要攒着。

> 注意：`godot_validate_script` 走的是它自己的加载路径（不是 `--check-only`，那个模式在 autoload 挂载前执行，会把所有 autoload 引用误报成 "Identifier not found"）。所以引用 autoload 单例的脚本用这个工具验证是可信的。

## 写新脚本的模板

```gdscript
extends CharacterBody2D
class_name Player
## 一句话说明这个节点是干什么的。

signal died

@export var speed: float = 300.0
@export var jump_force: float = -400.0

@onready var sprite: Sprite2D = $Sprite2D
@onready var _initial_hp: int = 100

var _hp: int = 100

func _physics_process(delta: float) -> void:
    var dir := Input.get_axis("move_left", "move_right")
    velocity.x = dir * speed
    if Input.is_action_just_pressed("jump") and is_on_floor():
        velocity.y = jump_force
    move_and_slide()

func take_damage(amount: int) -> void:
    _hp -= amount
    if _hp <= 0:
        died.emit()
        queue_free()
```

要点：`extends` + `class_name` + 一行文档注释、`@export` 暴露可调参数、`@onready` 引用节点、物理用 `_physics_process` + `move_and_slide()`。
