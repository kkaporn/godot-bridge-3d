extends SceneTree

# 验证 service_smoke.gd 的判据真的会红 —— 故意打一条不存在的命令和一个坏参数。
# 一个冒烟脚本如果永远绿，它就没在测东西。

const HOST := "127.0.0.1"
const PORT := 9090
const TIMEOUT_MS := 20000


func _initialize() -> void:
	# 1. 不存在的命令 —— 服务应把它当 PARAM（命令名错是调用方的锅）
	var r1: Dictionary = await _send("this_command_does_not_exist", {})
	print("unknown command     -> %s" % _classify(r1))

	# 2. 参数形状错 —— 应归 PARAM（调用方的锅），且服务必须还活着
	var r2: Dictionary = await _send("spawn_node", { "type": "NonexistentClass", "parent_path": "/root" })
	print("bad class name      -> %s" % _classify(r2))

	# 3. 抽象类 —— 应归 PARAM
	var r3: Dictionary = await _send("spawn_node", { "type": "CSGShape3D", "parent_path": "/root" })
	print("abstract class      -> %s" % _classify(r3))

	# 4. 探活 —— 服务必须还在
	var alive: Dictionary = await _send("get_scene_tree", {})
	print("server alive        -> %s" % _classify(alive))

	var ok := true
	for pair in [[r1, "PARAM"], [r2, "PARAM"], [r3, "PARAM"], [alive, "PASS"]]:
		if _classify(pair[0]) != pair[1]:
			ok = false
			print("  MISCLASSIFIED: expected %s got %s" % [pair[1], _classify(pair[0])])

	print("\nclassification check: %s" % ("all correct" if ok else "WRONG"))
	quit(0 if ok else 1)


func _send(cmd: String, params: Dictionary) -> Dictionary:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(HOST, PORT) != OK:
		return { "socket_error": true }
	var deadline: int = Time.get_ticks_msec() + TIMEOUT_MS
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		peer.poll()
		if Time.get_ticks_msec() > deadline:
			return { "timeout": true }
		await process_frame
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return { "socket_error": true }

	peer.put_data((JSON.stringify({ "id": 1, "command": cmd, "params": params }) + "\n").to_utf8_buffer())
	var buf := ""
	deadline = Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return { "socket_error": true }
		var avail: int = peer.get_available_bytes()
		if avail > 0:
			var got: Array = peer.get_data(avail)
			if got[0] == OK:
				buf += (got[1] as PackedByteArray).get_string_from_utf8()
				var nl: int = buf.find("\n")
				if nl >= 0:
					peer.disconnect_from_host()
					return { "json": JSON.parse_string(buf.substr(0, nl)) }
		await process_frame
	return { "timeout": true }


# 与 service_smoke.gd 完全相同的判据，用来交叉验证。
func _classify(r: Dictionary) -> String:
	if r.has("timeout") or r.has("socket_error") or not r.has("json"):
		return "BUG"
	var j: Dictionary = r["json"]
	if not j.has("error") and j.get("success", true) != false:
		return "PASS"
	var s: String = JSON.stringify(j)
	var call_site := false
	for pat in ["is not an", "Node not found", "not found:", "must be", "is required",
			"Unknown ", "Use ", "must have", "No "]:
		if s.contains(pat):
			call_site = true
			break
	var internal := false
	for pat in ["Invalid call", "Invalid get", "Invalid set", "Invalid index",
			"Invalid operands", "Invalid type", "Out of bounds", "Invalid access",
			"freed instance", "Parse Error", "null instance"]:
		if s.contains(pat):
			internal = true
			break
	if internal and not call_site:
		return "BUG"
	return "PARAM"