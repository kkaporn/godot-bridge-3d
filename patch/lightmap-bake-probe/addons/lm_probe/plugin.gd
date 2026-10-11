@tool
extends EditorPlugin

# Lightmap bake probe v6. Order matters: activate the 3D main screen, open the
# scene, SELECT the LightmapGI, and only then look for the bake button. The
# LightmapGIEditorPlugin instance is also located directly by class name in the
# editor tree, so the bake entry point does not depend on the button existing.

func _enter_tree() -> void:
	print("LMPROBE6_enter")
	_run()

func _run() -> void:
	await get_tree().process_frame
	EditorInterface.call("set_main_screen_editor", "3D")
	EditorInterface.call("open_scene_from_path", "res://lm.tscn")
	var guard := 0
	while EditorInterface.get_edited_scene_root() == null and guard < 900:
		await get_tree().process_frame
		guard += 1
	var scene_root = EditorInterface.get_edited_scene_root()
	if scene_root == null:
		print("LMPROBE6_FAIL no scene")
		get_tree().quit()
		return
	var lgi = scene_root.get_node_or_null("LightmapGI")
	print("LMPROBE6_lgi=", lgi)
	for i in 60:
		await get_tree().process_frame

	# select FIRST - the toolbar button only exists for a handled selection
	var sel = EditorInterface.get_selection()
	sel.clear()
	if lgi != null:
		sel.add_node(lgi)
	for i in 15:
		await get_tree().process_frame
	print("LMPROBE6_selection=", sel.get_selected_nodes())

	# locate the editor plugin node by class name (independent of the button)
	var base = EditorInterface.get_base_control()
	var plugin_nodes: Array = []
	_find_plugin(base, plugin_nodes)
	print("LMPROBE6_plugin_nodes=", plugin_nodes)
	var plugin_obj = null
	if plugin_nodes.size() > 0:
		plugin_obj = plugin_nodes[0]

	var buttons: Array = []
	_collect_buttons(base, buttons)
	var target = null
	for b in buttons:
		var t := str(b.text)
		if t.contains("光照") and t.contains("烘焙"):
			target = b
			break
	print("LMPROBE6_button=", (str(target.text) if target != null else "<none>"), " visible=", (target.is_visible_in_tree() if target != null else "-"), " disabled=", (target.disabled if target != null else "-"))

	if lgi != null and lgi.light_data == null:
		lgi.light_data = LightmapGIData.new()
		print("LMPROBE6_assigned_light_data=", lgi.light_data != null)

	if target != null:
		target.emit_signal("pressed")
		print("LMPROBE6_pressed emitted")
	if plugin_obj != null:
		print("LMPROBE6_calling _bake on ", plugin_obj.get_class())
		plugin_obj.call("_bake")

	var waited := 0
	var baked := false
	while waited < 1500:
		await get_tree().process_frame
		waited += 1
		if waited % 150 == 0:
			var lt := "textures=n/a"
			if lgi != null and lgi.light_data != null:
				var t2 = lgi.light_data.get_lightmap_textures()
				lt = "textures=" + str(t2.size() if t2 != null else -1)
			print("LMPROBE6_poll frames=", waited, " has_light_data=", (lgi.light_data != null if lgi != null else false), " ", lt)
		if lgi != null and lgi.light_data != null:
			var texs = lgi.light_data.get_lightmap_textures()
			if texs != null and texs.size() > 0:
				print("LMPROBE6_BAKED frames=", waited, " textures=", texs.size())
				for i in texs.size():
					print("LMPROBE6_tex", i, " size=", Vector2i(texs[i].get_width(), texs[i].get_height()))
				print("LMPROBE6_save=", EditorInterface.save_scene())
				print("LMPROBE6_lmbake_exists=", FileAccess.file_exists("res://lm.lmbake"))
				baked = true
				break
	if not baked:
		print("LMPROBE6_NO_BAKE frames=", waited)
	get_tree().quit()

func _find_plugin(node: Node, out: Array) -> void:
	if str(node.get_class()).contains("LightmapGIEditorPlugin"):
		out.append(node)
	for c in node.get_children():
		_find_plugin(c, out)

func _collect_buttons(node: Node, out: Array) -> void:
	if node is Button:
		out.append(node)
	for c in node.get_children():
		_collect_buttons(c, out)
