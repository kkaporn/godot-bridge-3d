extends SceneTree

# 通用「服务/接口全量冒烟」骨架 —— 改 TARGETS 就能测你自己的东西。
#
# 为什么需要它：手工点几十下必漏，而且会把「慢」误判成「坏」。脚本一次跑完，
# 并把结果分成三档，只有真缺陷才会红。
#
# 跑法：godot_run_headless --script res://tests/smoke.gd
#
# 三档判据（别混）：
#   PASS  —— 正常返回
#   PARAM —— 我参数/目标给错了，被测对象是活的
#   BUG   —— 被测对象内部崩了，或卡死 / 没响应
#
# 两个必须遵守的细节，否则会误报：
#   1. 超时窗口要大于被测命令自己的超时。默认 30 秒的命令配 8 秒超时 = 假死锁。
#   2. 一个目标把服务打死之后，后面全部会失败。每次失败都要再探一次活，
#      区分「这一个坏了」和「服务已经挂了」，否则会得到几十个假的独立缺陷。

const HOST := "127.0.0.1"
const PORT := 9090
const TIMEOUT_MS := 45000      # 必须 > 被测命令自身的超时
const PROBE_CMD := "get_scene_tree"   # 必定成功的命令，用来探活

# 要测的命令 + 最小合法参数。params 给不对只会得到 PARAM，不算 BUG。
const TARGETS := {
	"get_scene_tree": {},
	"get_performance": {},
	"eval": { "code": "return 1" },
	"wait": { "frames": 1 },
}

var _failures: Array[String] = []
var _counts := { "PASS": 0, "PARAM": 0, "BUG": 0, "SKIP": 0 }


func _initialize() -> void:
	print("smoke: %d target(s) -> %s:%d" % [TARGETS.size(), HOST, PORT])
	var dead_at := ""

	for cmd in TARGETS:
		if dead_at != "":
			_counts["SKIP"] += 1
			print("SKIP  %s  (server already dead at '%s')" % [cmd, dead_at])
			continue

		var r: Dictionary = await _send(cmd, TARGETS[cmd])
		var v: String = _classify(r)

		# 失败就探一次活，区分「这条坏了」和「服务挂了」。
		if v == "BUG" and (r.has("timeout") or r.has("socket_error")):
			var probe: Dictionary = await _send(PROBE_CMD, {})
			if _classify(probe) == "BUG":
				dead_at = cmd
				print("BUG   %s  ** KILLED THE SERVER **  %s" % [cmd, r.get("detail", "")])
				_counts["BUG"] += 1
				continue
			v = "PARAM"      # 偶发慢，服务还活着

		_counts[v] += 1
		print("%-5s %s%s" % [v, cmd, "  | " + str(r.get("detail", "")) if r.get("detail", "") != "" else ""])
		if v == "BUG":
			_failures.append("%s: %s" % [cmd, r.get("detail", "")])

	print("\n=== PASS %d | PARAM %d | BUG %d | SKIP %d ===" % [
		_counts["PASS"], _counts["PARAM"], _counts["BUG"], _counts["SKIP"]])
	for f in _failures:
		print("  BUG  " + f)
	quit(1 if _counts["BUG"] > 0 else 0)


# 发一条命令，返回 {json|timeout|socket_error|detail}。
func _send(cmd: String, params: Dictionary) -> Dictionary:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(HOST, PORT) != OK:
		return { "socket_error": true, "detail": "connect failed" }

	var deadline: int = Time.get_ticks_msec() + TIMEOUT_MS
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		peer.poll()
		if Time.get_ticks_msec() > deadline:
			peer.disconnect_from_host()
			return { "timeout": true, "detail": "connect timed out" }
		await process_frame
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return { "socket_error": true, "detail": "not connected" }

	var payload := JSON.stringify({ "id": 1, "command": cmd, "params": params }) + "\n"
	peer.put_data(payload.to_utf8_buffer())

	var buf := ""
	deadline = Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			peer.disconnect_from_host()
			return { "socket_error": true, "detail": "closed before response" }
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
					return { "socket_error": true, "detail": "unparseable response" }
		await process_frame
	peer.disconnect_from_host()
	return { "timeout": true, "detail": "no response within %d ms" % TIMEOUT_MS }


# 三档判据。关键是区分「调用方给错了」和「实现自己崩了」。
func _classify(r: Dictionary) -> String:
	if r.has("timeout") or r.has("socket_error"):
		return "BUG"
	if not r.has("json"):
		return "BUG"
	var j: Dictionary = r["json"]
	if not j.has("error") and j.get("success", true) != false:
		return "PASS"
	var s: String = JSON.stringify(j)
	# 调用方的锅：节点类型/路径/参数不对 —— 命令是活的。
	var call_site := false
	for pat in ["is not an", "Node not found", "not found:", "must be", "is required",
			"Unknown ", "Use ", "must have", "No "]:
		if s.contains(pat):
			call_site = true
			break
	# 实现方的锅：内部真的踩坑了。
	var internal := false
	for pat in ["Invalid call", "Invalid get", "Invalid set", "Invalid index",
			"Invalid operands", "Invalid type", "Out of bounds", "Invalid access",
			"freed instance", "Parse Error", "null instance"]:
		if s.contains(pat):
			internal = true
			break
	r["detail"] = s.substr(0, 180)
	if internal and not call_site:
		return "BUG"
	return "PARAM"
