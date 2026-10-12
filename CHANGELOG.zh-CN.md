# 更新日志

本文件记录本项目的所有重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [0.4.2] - 2026-10-12

### 修复

- **`remove_node` 能删掉场景树根，并把自己一起带走。** `remove_node {node_path: "/root"}` 返回 `{"success": true, "removed": "root"}`，随后交互服务器直接消失 —— 它是挂在 `/root` 下的 autoload，跟着一起被释放了，客户端收到 `ECONNREFUSED`。而服务器是唯一能撤销这个错误的手段，游戏只能手动重启。现在 `remove_node` 与 `reparent_node` 都调用共享的 `_refuse_server_fatal` 护栏，拒绝场景树根、服务器自身、以及服务器的任意祖先。**只检查被操作的节点** —— 把节点搬到 `/root` 下是最常见的正常用法，必须继续可用。

  这是模糊测试抓出来的，不是手工测出来的：没人会手工去试「删掉场景根」，因为没人觉得会有人这么干。正常参数测试根本走不到这条路径。

### 新增

- **`make-game/examples/interface_fuzz.gd`** —— 可复用的模糊测试骨架。每条命令灌一组恶意载荷（类型全错、缺字段、`null`、负数、`../` 路径、非法代码），**通过判据不是「命令成功」，而是「每次调用之后服务都还回答得动」**。它能区分「单条慢」「连接抖动」和「服务真死了」：探活带重试和间隔，因为上千次快速连接里单次探活失败会造成假阳性 —— 这个骨架的上一版就是这样误报了 103 个幻影锁死。实测：116 条命令 × 10 组载荷 = 1160 次调用，0 锁死，服务全程存活。
- **`godot-gdscript` 补「破坏性命令必须有护栏」一节。** 含规则、要拒绝的三类目标（场景树根、管理器自己、自己的祖先）、`_refuse_server_fatal` 实现，以及怎么找出风险调用点：搜 `.queue_free()` / `.free()` / `.reparent(` / `remove_child(`，逐个问「这个节点来自用户输入吗」。
- **`godot-gdscript` 在冒烟骨架旁边补「错误路径模糊测试」。** 只跑最小合法调用覆盖的是 happy path，而 happy path 不是 agent 会弄坏东西的地方。

### 变更

- **`godot-gdscript` 的「三种静默失败」更正了这两个骨架抓到的缺陷总数** —— 是 4 个不是 2 个：锁死服务、删掉场景根、报错误导、无视超时。

## [0.4.1] - 2026-10-12

### 修复

- **一个错误参数能永久锁死交互服务器。** `_handle_command` 只在「处理函数回了响应」或「客户端断开」两种情况清 `_busy`。处理函数若在 GDScript 运行时报错处中止，它永远走不到 `_send_response`，`_busy` 就一直为真，**之后每一条**命令都被拒为 `Server busy`，必须重启游戏。`procedural_mesh` 在参数形状写错时正好踩到这条路。现在 dispatch 在 match 之前置哨兵 `_responded`，若处理函数没回就替它回一个明确错误并释放槽位。验证方式：注入一条必然在函数中途崩掉的命令 —— 服务器返回 `Command '_boom' aborted on a script error … The server stayed responsive.` 并继续正常服务。
- **`procedural_mesh` 现在同时接受两种向量形状。** 它读的是 `v[0]`/`v[1]`/`v[2]`，所以传 `{"x":…,"y":…,"z":…}`（同一插件里其它命令用的形状）会抛 `Invalid index`，并触发上面那条锁死。新增 `_to_vec3`/`_to_vec2` 接受数组或字典两种写法，顶点、法线、UV 都走它。
- **`http_request` 无视调用方的超时，且把失败报成成功。** 它裸 `await request_completed`，连不上的主机能把 `_busy` 占满整个 30 秒默认值且无法缩短；而无论请求成败，响应都固定是 `{"success": true, …}`。现在信号与定时器赛跑，失败时返回 `success: false` 和 `HTTPClient` 的结果码；对本地监听器实测返回了正确的 200 与 body。
- **`spawn_node` 对抽象类报 `Failed to instantiate`，误导人。** `ClassDB.class_exists()` 对 `CSGShape3D`、`Shape3D`、`BaseButton` 之类都返回 true，但 `instantiate()` 返回 null。现在报错会说明这是抽象类并列出具体子类（`Try one of: CSGMesh3D, CSGSphere3D, CSGBox3D, …`）。

### 新增

- **`godot-gdscript` 补「三种静默失败」一节。** GDScript 不抛异常：运行时报错只打印一行，然后中止当前函数并返回 null。三个后果都是实际踩过的 —— 报错之后的语句一行都不执行；被跳过的收尾调用会锁死它正在持有的东西（`_responded` 哨兵写法已写入）；失败的类型转换会静默给默认值（`float("abc") == 0.0`，字符串转 `Vector3` 得零向量），所以**「没报错」永远不等于「值是对的」**。
- **`godot-gdscript` 补参数形状规则与抽象类对照表。** 向量参数会以 `[1,2,3]` 或 `{"x":1,…}` 两种形状到来，取决于调用方；一个共用的 `_to_vec3` 好过在每个调用点重复写 `v[0]`。
- **`make-game/examples/service_smoke.gd`** —— 可复用的全接口冒烟骨架。每个目标发一次最小调用，结果分三档：PASS / PARAM（调用方给错了目标或参数）/ BUG（被测对象自己失败或卡死）；每次失败后再探一次活，避免一个服务被打死后读成几十个互不相关的缺陷。实测覆盖 116 条交互服务器命令，再加 38 条配好节点场景的命令：**153 次调用，0 缺陷**。
- **`make-game/examples/classify_check.gd`** —— 证明上面那个冒烟骨架的判据不是空转。永远绿的冒烟脚本等于没测；这个脚本断言「目标给错 → PARAM」「服务活着 → PASS」。
- **`godot-gdscript` 把冒烟骨架方法写进「先算，再看」。** 手工点几十条命令和从截图读数字一样不可靠，而且会把「慢」误标成「死」。两个必须遵守的细节已记录：socket 超时要大于命令自身超时；必须区分「服务挂了」和「单条命令坏了」。

### 变更

- **`scripts/install-skills.test.mjs` 改为报告真实字节数。** 它打印的是 `String.prototype.length` 却标成 bytes；技能文件几乎全是中文，一个 UTF-16 码元 = 3 个 UTF-8 字节，所以数字偏低约 45%，看起来像安装被截断了。

## [0.4.0] - 2026-10-12

### 新增

- **「先算，再看」写进三个技能的硬规则。** 此前 agent（和人）在 3D 上反复犯的同一个错是凭截图判断数值对不对：一个地形原型在「看起来不够立体」上卡了三轮，每轮都在凭感觉调参数，第四轮才发现是 96 宽只有 29 高的宽高比问题。现在明确了判据：**能写成数字的先写成断言，`godot_run_headless --script` 跑通再看截图；截图只用来确认，不用来验证。** 但造型偏好不是数学问题，不得伪装成断言，也不得拿「审美」当算错的借口。
- **`godot-gdscript` 补 3D 空间数学一节（规则 16–21）。** 全部来自一次真实的程序化骨骼+蒙皮实现，每个都是断言抓到而非眼睛发现：
  - 用 `class_api` 查类的方法，不要凭记忆（参数名是 `class_name` 不是 `class`）。
  - **`Skeleton3D` 没有 bind 方法**，bind 在 `Skin` 资源上 —— 写错会得到 `Invalid call. Nonexistent function 'get_bind_pose'`。
  - **Godot 4 的 rest 与 pose 是两个独立量**，新建骨架的 pose 是 identity 而非 rest；渲染器用 pose，所以只设 rest 会让所有顶点在第一帧跳一下，且 `reset_bone_poses()` 在未设过 pose 时是空操作。
  - **骨骼 rest 是父骨空间的局部变换**，不是世界坐标 —— 写绝对位置会让每个父骨偏移被算两遍。
  - **LBS 公式里 bind 不要重复取逆**：`get_bind_pose()` 已含逆，再取一次等于把偏移平方。bind 也要用**全局** rest 的逆来建。
  - **`SurfaceTool` 没有骨骼权重 API**（4.7 只有 `set_bones`），权重必须直写 `Mesh.ARRAY_BONES` / `ARRAY_WEIGHTS`，且补齐占位前要按权重降序排。
- **`make-game` 新增「程序化资产」一节。** 明确回答「能不能直接生成树/山/角色」：能。地形用 `FastNoiseLite` + 域扭曲、体素世界用 `GridMap`、有机形体用 `procedural_mesh`（接受任意顶点数组，不限形状）、复合体用 `CSG`。角色骨骼+蒙皮同样完全可算 —— LBS 就是 `v' = Σ wᵢ · Bᵢ · v`，没有算不出来的部分；给出七步流程与四项必备断言。
- **`make-game/examples/` 收录两个已验证的可运行脚本** —— `procedural_rig.gd`（20 骨骼、1330 顶点、2280 三角面）与 `rig_check.gd`（8 项断言全过）。技能里的流程不再是空话，拷进项目直接跑。
- **`godot-playtest` 补「截图缓存」与「相机朝向用公式判」。** `screenshot` 在换场景或停启后会返回上一帧画面，而 `get_scene_tree` 显示的是新场景 —— 判据是连续截两次看 base64 是否逐字节相同，命中则改用 `eval` + `save_png`。同时补上 3D 黑屏最常见的原因：相机背对主体，给出计算朝向夹角的方法，以及为什么该用 `look_at` / `look_at_from_position` 而不是手填欧拉角。

## [0.3.0] - 2026-10-12

### 新增

- **内置游戏开发技能。** 工具负责驱动 Godot，技能负责告诉 agent 该驱动它做什么。`skills/` 收录三个中文技能，正文里直接点名本插件的工具，让 agent 照着走一条验证过的流程，而不是即兴发挥：
  - `make-game` —— 「我想做一个游戏 / 不知道怎么开始」这条路：确认核心动作、失败条件、2D 还是 3D，先做出最小可玩切片，然后一层一层加、每层都验证，最后导出。
  - `godot-gdscript` —— 最耗时间的那批 GDScript 陷阱：`clamp()` 返回 `Variant` 在 `:=` 下报错、`BaseMaterial3D.new()` 是整份脚本挂掉的解析错误、`$` 在 `_ready()` 之前返回 null、`%UniqueName` 没勾 `unique_name_in_owner` 时静默为 null、`await` 一个永不发出的信号，外加一张八行的「运行时报错 → 真正原因」对照表。
  - `godot-playtest` —— 验证循环：启动、按键、截图、读日志。包含 `key_hold` / `key_release` 必须配对（漏掉 release 会让一个方向一直卡住）、黑屏排查顺序，以及无头 assert 脚本测试。
- **技能在插件加载时自动安装。** `apply()` 把每个 `skills/<slug>/SKILL.md` 镜像进 DSH 用户技能目录（`$DSH_HOME/skills`，默认 `~/.dsh/skills`）——那是宿主唯一会发现技能的地方；包内的技能目录对 DSH 不可见。每次加载都无条件覆写：这些是插件管理的文件，技能正文又点名了本插件的工具，副本过期正是脱节的方式。用户自己建的技能目录不会被读取也不会被删除。全程尽力而为——主目录不可写时工具照常工作，只记一条警告。
- **`godot_ping` 返回 `skills` 字段** —— 已安装的技能 slug，会话里不必翻文件系统就能确认知识层到位。
- **一条指向技能的 system-prompt 分区**（`godot-bridge:skills`，order 153）—— 没有它 agent 没有理由去加载技能；分区里逐个写明触发条件。
- **`scripts/lint-skills.mjs`（capability lint）。** 技能是模型当作指令执行的 Markdown，一行被污染的文本就会被原样执行。七条规则覆盖 `skills/` 下每个 `.md`：`url-allowlist`（回环地址始终放行——9090 上的交互服务器正是如此）、`install-command`（包管理器、`curl|sh`、`npx <第三方包>`）、`credential-pattern`、`base64-blob`（160 字符阈值，含跨两行折行）、`invisible-unicode`（零宽、双向控制、tag 块）、`prompt-injection-phrase`、`destructive-command`。技能可用 `<!-- lint-allow rule-id: 理由 -->` 豁免某条规则，且每一处豁免都会打印出来。
- **`scripts/lint-skills.test.mjs`（25 个用例）。** 一个悄悄失配的 lint 比没有 lint 更糟——因为 CI 照样绿。所以每条规则都有一个必须命中的坏样本，也有必须不命中的好样本。不可见字符与 base64 样本是**程序生成**而非直接写进源码：粘进源码的零宽字符会被编辑器悄悄删掉，那样测试会因为错误的原因而通过。
- **`scripts/install-skills.test.mjs`** —— 验证安装步骤逐字节复制每个技能，且每个 `SKILL.md` 都带宿主能索引的 frontmatter。

### 变更

- `npm run check` 现在同时跑契约检查与技能 lint，CI 会在抓到被污染的技能的同时抓到坏掉的组合包。
- `npm test` 运行两个测试文件。

## [0.2.0] - 2026-10-01

### 新增

- **`Godot engine path` 现在可以在 GUI 里编辑。** 本组合包自带浏览器半侧（`client/client.js`，在 manifest 里由 `dsh.client` 声明），以包名为键注册本组合包的配置区（keyed slot `plugins.bundle.config`）——插件页的 **godot-bridge 卡片页**因此直接在描述与行列表之间显示路径字段，带**保存**与针对本 profile 覆盖值的**恢复默认**。（按行注册的 `plugins.row.config`（键为 `<包名>#<行 id>`）会把同一个表单放到深一层、藏在行上的「配置」控件后面；等到一个组合包拥有多个可独立配置的行时它才是正确选择，而本包只有一个。）保存走的是 DSH 设置的同一条路，落到 `godot_set_engine_path` 写入的同一行 `cordis.patch.yml`，所以该字段、那个工具、以及手写的 `config:` 块是同一个值的三种视角，改动立即生效、无需重启。关闭那一行时配置区随之消失——浏览器半侧属于那一行。本条关闭了下方 0.1.8 记录的已知限制。
- `npm run check` 现在同时校验浏览器半侧，把「让组合包失去表单」这一类错误变成构建期失败，而不是运行期静默失败：`dsh.client` 声明（合法成员、`platform: 'web'`、字符串数组 `inject`/`external`、布尔 `immediately`）、`exports["./client"]` 目标存在且被 `files` 覆盖、`window.__ModuleLoader__.load({ id })` 的 id 等于包名、`slots` 服务声明、每个 `require()` 说明符是否落在 web 客户端平台种子模块表或 `dsh.client.external` 内、`plugins.bundle.config` 的键是否等于本包名，以及 `plugins.row.config` 的键是否指向本包 patch 声明的行。slot 键与模块请求都只从**代码**读，注释不能充当通过条件。

### 变更

- 浏览器半侧在无法承载它的运行时上保持静默：0.1.6–0.1.x 已有这些 slot，但没有可读该值的设置表单服务，因此注册包在 `ctx.inject(['configForms'], …)` 之内，那些运行时维持原有行为（没有 GUI 字段，仍用 `godot_set_engine_path` 与 `settings.yaml`）。比 0.1.0-rc.7 更早、根本不扫描 `dsh.client` 的运行时忽略该 manifest 成员。

## [0.1.8] - 2026-09-30

### 修复

- 以 `link:` 依赖安装时，插件在 DSH 0.2.x 上完全无法加载：launcher 的 runtime resolution 只对「linked 包在自己 `peerDependencies` 里声明过的名字」把 `@deepseek-ai/*` 路由到安装版（它读的是 `peerDependencies` 的键，不是 `dependencies`），而 godot-bridge 一个都没声明——于是 `import '@deepseek-ai/dsh-tools'` 报 `ERR_MODULE_NOT_FOUND`，17 个 `godot_*` 工具一个都没注册。manifest 现在声明 `@deepseek-ai/dsh-tools` 与 `@deepseek-ai/schemastery`。
- `godotPath` 在 DSH 0.2.x 上不再消失：`@deepseek-ai/dsh-settings` 移除了 `register`，settings 段此前只会静默降级成一条告警，`godot_set_engine_path` 永远回答 settings 服务不可用。
- 在 0.1.x → 0.2.x 升级前配置过的引擎路径会被自动带过来，而不是静默回落到 PATH 上的 `godot`（那通常是版本管理器 shim，也就是与用户当初配置不同的构建）。见「变更」中的迁移说明。

### 变更

- 配置模型：`godotPath` 改为插件 Config 的 `.volatile()` 字段，因此会出现在插件设置页，并按活值读取（volatile 字段原地更新，不 remount 插件）。写入经 `ctx.configEditor.edit(...)` 持久化到 active profile 的 `cordis.patch.yml` 并热重组——无需重启。
- `godot_set_engine_path` 写前校验目标文件是否存在，并回报持久化去向：DSH 0.2.x 上为 `persisted: 'profile-patch'`，旧路径为 `'settings'`。
- 继续兼容旧运行时：0.1.6–0.1.x 上 `settings.register` 仍然存在时插件继续使用它（`@deepseek-ai/dsh-tools` 的声明范围为 `>=0.1.6-0`）。`peerDependenciesMeta.optional` 阻止 pnpm 去 registry 安装 harness 包。
- `settings.yaml` 迁移：DSH 0.2 按插件 entry id 导入遗留段，而本插件的行 id 是 `tool-godot-bridge`，所以 0.1.x 写下的 `godot-bridge:` 段不会被带过来。当当前运行时没有配置路径时，插件会读取该段并把其中的值经与 `godot_set_engine_path` 相同的 profile-patch 写入路径写回，因此升级前配置的引擎构建无需重新填写即可继续使用。已配置的值永远不会被覆盖；记录在磁盘上已不存在的路径会被忽略（这种情况仍保留 PATH 兜底与对应告警）。还原每次插件加载只尝试一次，且尽力而为：写入被拒时保留 PATH 兜底并记一条告警，不会禁用任何工具。

### 新增

- `npm run check` —— `scripts/check-plugin-contract.mjs`：零依赖静态契约检查。裸 `@deepseek-ai/*` import 必须在 `peerDependencies`/`dependencies` 中声明；`dsh.bundle.patch` 必须存在且引用本包；`main`/`exports` 目标文件必须存在且被 `files` 覆盖；入口必须导出 `name`/`apply` 且没有 `export default`。
- `scripts/diagnose-dsh-resolution.mjs` —— 可重跑的 launcher runtime resolution 诊断（bundle 层、被 skip 的 bundle、linked root、每个 import 的解析结果，支持 `--expect ok|fail`）；仅开发用，不发布。

### 文档

- README：新增「DSH 0.2+ 兼容性与故障排查」（解析规则、`link:` 的 peer 要求、症状对照表、`dsh plugin allow-version` 应急、验证命令），并修正配置位置的表述。
- install：新增 `link:` 本地开发一节；重写「配置」一节（volatile 字段、profile-patch 写入路径、旧运行时兜底、`settings.yaml` 迁移说明）；维护一节补上契约检查与诊断脚本。
- ARCHITECTURE：新增「依赖契约与运行时解析」及分层示意图。

### 已知限制

- `godotPath` 在 DSH 0.2 上**没有 GUI 表单项**。插件页只为「自带客户端组件、注册了 keyed slot `plugins.row.config`」的插件渲染行配置表单；没有任何内置包注册该插槽，而 godot-bridge 没有客户端入口。Host 侧不受影响——`settings.describe()` 仍会为 `tool-godot-bridge` 行投影该字段，用 `godot_set_engine_path`（或该行的 `config:` 块）设置即可。该缺口单独作为功能请求跟踪。

## [0.1.7] - 2026-09-07

### 修复

- 旧版 autoload 残留导致端口路由失效：若项目 `autoload/mcp_interaction_server.gd` 早于 `GODOT_BRIDGE_PORT`/`get_instance_info` 引入，无论 `godot_run_project` 请求什么端口都只会绑 9090——于是 `port=9092` 看似成功，后续 `godot_command`/`godot_screenshot` 却只能找到 9090（issues #4）。`ensureInteractionAutoload` 现在会用随包版本覆盖过期的 autoload（该文件属插件管理的基础设施），并在替换时返回 `upgraded`。
- `godot_ping` 与错误文案改为上报真实探测端口，不再写死 `127.0.0.1:9090`。
- `writeProjectFile` 的 fs policy 改为指向目标项目目录而非会话工作区，使对工作区外项目的 autoload/project.godot 写入合法。
- 所有工具返回出口接入 `sanitizeLossless` 防御：偶发的 `undefined`/`NaN` 字段降级为日志记录并修正，而不是静默报 `value is not lossless JSON`。

## [0.1.6] - 2026-09-01

### 新增

- `godot_run_project` 的实例归属处理：先探测端口，若同项目已有实例在运行（典型场景：用户在编辑器里启动了场景，LLM 再运行项目），**直接接管（adopt）**并返回 `external: true`，不再 spawn 一个绑定失败、静默错挂的重复实例（旧行为会制造一个裸奔副本并误驱动用户实例）。
- 异项目占用端口时自动回退到 9091+（或调用方传入的 `port` 参数），不再撞端口。
- `mcp_interaction_server.gd` 支持 `GODOT_BRIDGE_PORT` / `GODOT_BRIDGE_TOKEN` 环境变量，并新增 `get_instance_info` 命令（pid/port/token/project），作为归属识别的身份基础。
- `godot_stop_project` 拒绝终止被接管（用户/编辑器启动）的实例，并说明安全停止方式（编辑器按 F8 / 游戏内退出）；插件绝不杀死自己未启动的进程。新增 `godot-bridge:instance-ownership` 系统提示段，同样禁止用 pwsh 杀进程（会连带把编辑器带崩）。

### 修复

- 兼容 dsh-settings ≥ 0.1.2-alpha：移除已删除的 `settingsNamespace` 导出（改为把裸字符串命名空间传给 `ctx.settings.register`）；settings 与工具注册均加防御式 try/catch，未来 API 再漂移时降级告警而不是拖垮整个 host 启动。

## [0.1.5] - 2026-08-19

### 新增

- `godot_run_headless` 工具：通过不受文件沙箱约束的 subprocess 服务执行有界的 headless 场景/逻辑/测试运行（`godot --headless --path <项目> [--quit-after N] [--script <脚本.gd>]`，超时强杀），取代在受沙箱约束的 pwsh/bash shell 里直接跑 `godot --headless` 导致 signal 11 崩溃的危险做法。

### 变更

- `godot_headless_op` / `godot_validate_script` / `godot_export_project` 崩溃时附带 `diagnosis`（`sandbox-crash`，高/低置信度 + 可执行提示），不再只返回原始 stderr，沙箱崩溃不再被误判为项目 bug。
- 新增 `godot-bridge:launch-channel` 系统提示段：Godot 必须始终通过 godot_* 工具（不受沙箱约束的 subprocess）启动，严禁通过 pwsh/bash（文件沙箱拦截 user:// 日志写入，signal 11 崩溃）。
- `godot_run_project` 描述指向 `godot_run_headless` 用于非交互 headless 运行。

### 修复

- `godot_run_headless` 在正常路径返回 `note: undefined`；DSH 工具层会拒绝任何 `undefined` 属性（"value is not lossless JSON"）并丢弃整个结果。现在 `note` 仅在超时时存在，`exit_code` 归一化处理，确保每个返回字段都是 lossless JSON。
- `godot_validate_script` 的错误条目在缺失文件/行号定位时使用 `null`（而非 `undefined`）。

## [0.1.4] - 2026-08-16

### 修复

- 恢复 0.1.3 中误删的 `timer` 注入：`ctx.timeout()` 是 timer 服务的 mixin，其 getter 读取 `ctx.timer`，移除后导致 `godot_run_project` / `godot_command` / `godot_screenshot` 报 `cannot get property "timer" without inject`。

## [0.1.3] - 2026-08-15

### 新增

- `godot_set_engine_path` 工具：模型向用户索要 Godot 可执行文件路径并写入 settings（schema 与存在性双重校验、热重载、无需重启），补全"未配置引擎"的引导闭环。

### 变更

- `godotPath` 现在是面向用户的 settings 值（Web 插件配置页或 `settings.yaml` 的 `godot-bridge:` 段），不再是 `cordis.patch.yml` 的行配置；插件作者不再预设路径（Godot 是便携 exe，可能位于任意位置）。
- Godot 可执行文件解析顺序：每次调用的 `godot_path` 参数 → `godotPath` 设置 → PATH 上的 `godot` 命令。`godot` 已在 PATH 时无需任何配置。
- 存在性校验从 `apply` 内的 `throw`（会令整个 fiber 失败）移到 settings 的 `validate` 钩子，坏路径不再连累纯文件工具。

### 修复

- 工具描述不再把配置位置误写为 `$DSH_HOME/settings.yaml`（现指向 settings 段，与代码实际读取一致）。

### 移除

- 冗余的 `timer` 注入与 `console.log` 噪声（改用 `ctx.logger`）。

## [0.1.2] - 2026-08-15

### 修复

- 更新提示现在能可靠送达模型：`systemPrompt` 改为注入（此前用惰性 `ctx.get`，可能拿不到服务），提示文本改为明确指令，模型会在每个会话中主动转达"有可用更新：已装 X，最新 Y"。
- `godot_ping` 返回 `plugin_version` / `latest_version` / `update_available`，可随时按需查询。

## [0.1.1] - 2026-08-15

### 新增

- 启动时更新提示：尽力而为的版本检查，抓取仓库 `main` 分支的 `package.json`（`raw.githubusercontent.com`，5 秒超时，失败/离线静默跳过）。存在更新时注册一条系统提示；`package.json` 的 `repository` 字段让 fork 自动跟随检查源。

### 修复

- `godot_command` 的 `timeout_ms` 此前是死参数：一次性 node 桥固定 20 秒封顶。现在超时经 `argv[3]` 传入（缺省 20 秒），`godot_ping`、`godot_run_project` 的就绪轮询以及异步命令都能按各自的超时生效。

### 变更

- 移除 pre-bundle 部署遗留的 headless 脚本兜底路径（`<项目>/tools/godot-bridge/`、`../godot-mcp/src/scripts/`）；模块同目录副本成为唯一来源。

## [0.1.0] - 2026-08-15

首个版本——以原生 Agent 工具取代 godot-mcp MCP 服务器的标准 DSH bundle。

### 新增

- 15 个 `godot_*` 工具：
  - 进程：`godot_run_project` / `godot_stop_project` / `godot_get_debug_output` / `godot_ping`
  - 运行时控制：`godot_command`（覆盖全部交互服务器命令）、`godot_screenshot`
  - headless：`godot_headless_op`（16 个操作）/ `godot_validate_script`
  - 项目编辑：`godot_set_project_setting` / `godot_manage_autoloads` / `godot_manage_input_map` / `godot_manage_export_presets` / `godot_create_script` / `godot_create_project` / `godot_export_project`
- 标准 DSH bundle 形态：`@deepseek-ai/dsh-tools` 的 `defineTool` + `ctx.tools.register`；`dsh.bundle` manifest 支持 `dsh plugin --profile web add github:Smalldy/godot-bridge` 安装。
- 随包附带游戏侧资产：`mcp_interaction_server.gd`（游戏内 TCP autoload）、`godot_operations.gd`、`validate_script.gd`。
- `godot_manage_input_map` 使用正确的 Godot 4 键码（修复 godot-mcp 的 Godot 3 基线 bug）。
- 双语文档（README / install / ARCHITECTURE / COVERAGE），含安装与移除指南；`cordis.patch.yml` 纳入发布 `files`。

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
