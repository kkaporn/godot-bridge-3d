extends SceneTree

# 接口模糊测试骨架 —— 给每条命令灌错类型的参数，验证「无论如何都锁不死服务」。
#
# 为什么需要它：只跑一遍合法调用覆盖的是 happy path，而 agent 最容易走到的
# 是错误路径（它会把参数拼错）。真正的坑都在那里。
#
# 真实收获：这一轮靠它抓到 remove_node {node_path:"/root"} 会删掉场景树根，
# 连带删掉挂在下面的服务器 —— 返回 success:true 然后客户端 ECONNREFUSED，
# 游戏只能手动重启。正常参数测试永远碰不到这条路。
#
# 跑法：godot_run_headless --script res://tests/fuzz.gd
#      （要求游戏已经跑起来；本脚本通过 TCP 打它自己的交互服务器）

const HOST := "127.0.0.1"
const PORT := 9090
const CALL_TIMEOUT_MS := 12000     # 单条调用的等待
const PROBE_CMD := "get_scene_tree"

# 要模糊的命令。加你自己的接口名进来。
const COMMANDS := [
	"screenshot", "get_scene_tree", "get_property", "set_property",
	"call_method", "get_node_info", "remove_node", "reparent_node",
	"spawn_node", "eval", "instantiate_scene", "change_scene",
]

# 恶意载荷：类型全错、缺字段、null、超长、负数、越界路径、非法代码。
# 目标不是让命令成功，而是看它崩的时候会不会把服务一起带走。
const PAYLOADS := [
	{},
	{ "node_path": 12345, "action": 999, "name": null },
	{ "node_path": "/root/../../etc" },
	{ "node_path": "/root" },
	{ "action": "nonexistent_action", "node_path": null },
	{ "from": "not-a-vector", "to": 42 },
	{ "parent_path": -1, "count": "many" },
	{ "scene_path": "", "signal_name": [], "method": {} },
	{ "code": "THIS IS NOT GDSCRIPT ((((" },
	{ "type": "NotARealClass", "parent_path": "/root" },
]

var _wedges := 0
var _replies := 0
var _flaky := 0


func _initialize() -> void:
	var total: int = COMMANDS.size() * PAYLOADS.size()
	print("fuzz: %d commands x %d payloads = %d calls" % [COMMANDS.size(), PAYLOADS.size(), total])
	if not await _alive():
		print("server not up — start the game first")
		quit(1)
		return

	var dead := false
	for cmd in COMMANDS:
		if dead:
			print("... skipping %s (server already dead)" % cmd)
			continue
		for i in PAYLOADS.size():
			var r: Dictionary = await _send(cmd, PAYLOADS[i])
			if r.has("json"):
				_replies += 1
				continue

			# 没拿到响应：区分「单条慢」「连接抖动」和「服务真死了」。
			# 探活必须重试并留间隔 —— 上千次快速连接本身有 TCP 抖动，
			# 一次失败就判死会造成大量假阳性。
			if not await _alive():
				_wedges += 1
				dead = true
				print("WEDGE  %s  payload#%d  -> %s" % [cmd, i, r.get("detail", "no reply")])
				break
			_flaky += 1
			print("flaky  %s  payload#%d  (server alive)" % [cmd, i])

	print("\n=== replies %d | flaky %d | WEDGES %d ===" % [_replies, _flaky, _wedges])
	var final_ok: bool = await _alive()
	print("server alive after full fuzz: %s" % final_ok)
	quit(1 if _wedges > 0 or not final_ok else 0)


# 探活：重试一次，避免把 TCP 抖动当成服务死亡。
func _alive() -> bool:
	for attempt in 2:
		var r: Dictionary = await _send(PROBE_CMD, {})
		if r.has("json") and not (r["json"] as Dictionary).has("error"):
			return true
		if attempt == 0:
			await create_timer(0.3).timeout
	return false


func _send(cmd: String, params: Dictionary) -> Dictionary:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(HOST, PORT) != OK:
		return { "detail": "connect failed" }

	var deadline: int = Time.get_ticks_msec() + CALL_TIMEOUT_MS
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		peer.poll()
		if Time.get_ticks_msec() > deadline:
			peer.disconnect_from_host()
			return { "detail": "connect timed out" }
		await process_frame
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		peer.disconnect_from_host()
		return { "detail": "not connected" }

	peer.put_data((JSON.stringify({ "id": 1, "command": cmd, "params": params }) + "\n").to_utf8_buffer())

	var buf := ""
	deadline = Time.get_ticks_msec() + CALL_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			peer.disconnect_from_host()
			return { "detail": "closed before response" }
		var avail: int = peer.get_available_bytes()
		if avail > 0:
			var got: Array = peer.get_data(avail)
			if got[0] == OK:
				buf += (got[1] as PackedByteArray).get_string_from_utf8()
				var nl: int = buf.find("\n")
				if nl >= 0:
					peer.disconnect_from_host()
					var parsed: Variant = JSON.parse_string(buf.substr(0, nl))
					if parsed is Dictionary:
						return { "json": parsed }
					return { "detail": "unparseable response" }
		await process_frame
	peer.disconnect_from_host()
	return { "detail": "no response within %d ms" % CALL_TIMEOUT_MS }
