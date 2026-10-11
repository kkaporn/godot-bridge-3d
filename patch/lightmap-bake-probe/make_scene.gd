extends SceneTree

# Builds res://lm.tscn for the lightmap-bake probe: meshes carry real UV2
# (ArrayMesh.lightmap_unwrap), gi_mode=STATIC, a static DirectionalLight3D and a
# LightmapGI as a DIRECT CHILD of the scene root (the editor bake button only
# looks at direct children).

func _box(name: String, size: Vector3, pos: Vector3, root: Node3D) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	var am := ArrayMesh.new()
	for i in bm.get_surface_count():
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, bm.surface_get_arrays(i))
	var err: int = am.lightmap_unwrap(Transform3D.IDENTITY, 0.4)
	var uv2 = am.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = am
	mi.position = pos
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	root.add_child(mi)
	mi.owner = root
	print("mesh ", name, " unwrap_err=", err, " has_uv2=", uv2 != null, " verts=", am.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size())

func _init() -> void:
	var root := Node3D.new()
	root.name = "LightmapTest"

	var env := WorldEnvironment.new()
	env.name = "WorldEnvironment"
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.06, 0.08)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.12, 0.12, 0.15)
	env.environment = e
	root.add_child(env)
	env.owner = root

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.light_energy = 1.2
	sun.set("light_bake_mode", 1)  # 1 = BAKE_STATIC
	root.add_child(sun)
	sun.owner = root

	_box("Floor", Vector3(12, 0.2, 12), Vector3(0, -0.1, 0), root)
	_box("WallBack", Vector3(12, 4, 0.2), Vector3(0, 2, -6), root)
	_box("WallLeft", Vector3(0.2, 4, 12), Vector3(-6, 2, 0), root)
	_box("Crate", Vector3(1.4, 1.4, 1.4), Vector3(0, 0.7, 0), root)
	_box("Pillar", Vector3(0.8, 3, 0.8), Vector3(2.5, 1.5, 2), root)

	var lgi := LightmapGI.new()
	lgi.name = "LightmapGI"
	lgi.set("bake_quality", 1)  # 1 = medium
	root.add_child(lgi)
	lgi.owner = root

	var ps := PackedScene.new()
	var pack_err: int = ps.pack(root)
	var save_err: int = ResourceSaver.save(ps, "res://lm.tscn")
	print("pack_err=", pack_err, " save_err=", save_err)
	quit()
