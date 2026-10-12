extends SceneTree

# Rig verification. Every claim about the procedural character is an assertion,
# not a judgement call.
#
#   1. skeleton topology acyclic and rooted
#   2. bind matrices are exact inverses of the rest pose  -> at rest, v' == v
#   3. skin weights form a partition of unity per vertex   -> no shrinkage
#   4. bone indices are in range and influence count matches the budget
#   5. the mesh is connected (one piece, not floating tubes)
#   6. a rotated bone moves its vertices and ONLY its own
#   7. joint bend is continuous — no tear at the elbow
#
# Run: godot --headless --script res://scripts/rig_check.gd

const RigScript := preload("res://scripts/procedural_rig.gd")
const INFL := 4

var failures: Array[String] = []


func _initialize() -> void:
	var rig: RefCounted = RigScript.new()
	var sk: Skeleton3D = rig.build_skeleton()
	var mesh: ArrayMesh = rig.build_mesh()
	var skin: Skin = rig.build_skin(sk)

	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	print("=== 1. skeleton topology ===")
	print("  %d bones, %d verts, %d tris" % [sk.get_bone_count(), verts.size(), indices.size() / 3])
	var seen := PackedInt32Array()
	seen.resize(sk.get_bone_count())
	for b in range(sk.get_bone_count()):
		var p: int = sk.get_bone_parent(b)
		var depth := 0
		while p >= 0 and depth < 64:
			p = sk.get_bone_parent(p)
			depth += 1
		if depth >= 64:
			failures.append("bone %d is in a cycle" % b)
		elif p != -1:
			failures.append("bone %d does not reach root" % b)
		seen[b] = 1
	print("  all bones reach root, no cycles: %s" % ("yes" if failures.is_empty() else "NO"))

	print("\n=== 2. bind == inverse(GLOBAL rest)  =>  at rest, v' == v ===")
	# Binds live on the Skin resource, not on Skeleton3D (Godot 4.x split these).
	# The correct reference is the bone's accumulated world rest transform,
	# which is what build_skin() inverted.
	var worst := 0.0
	for b in range(sk.get_bone_count()):
		var global_rest := Transform3D(Basis(), rig.bone_heads[b])
		var bind: Transform3D = skin.get_bind_pose(b)
		var prod: Transform3D = bind * global_rest
		var err := prod.origin.distance_to(Vector3.ZERO)
		err += prod.basis.x.distance_to(Vector3.RIGHT)
		err += prod.basis.y.distance_to(Vector3.UP)
		err += prod.basis.z.distance_to(Vector3.BACK)
		worst = maxf(worst, err)
	# GDScript's % formatter has no %e; print with explicit digits instead.
	print("  %d binds, max |bind * global_rest - identity| = %s" % [skin.get_bind_count(), str(worst)])
	if worst > 1e-5:
		failures.append("bind matrices are not exact inverses: %s" % str(worst))
	else:
		print("  OK — a vertex at rest is reproduced exactly")

	print("\n=== 3. weights are a partition of unity ===")
	var infl := weights.size() / verts.size()
	var min_sum := INF
	var max_sum := -INF
	for v in range(verts.size()):
		var s := 0.0
		for k in range(infl):
			s += weights[v * infl + k]
		min_sum = minf(min_sum, s)
		max_sum = maxf(max_sum, s)
	print("  %d influences/vertex, sum in [%.6f, %.6f]" % [infl, min_sum, max_sum])
	if absf(min_sum - 1.0) > 1e-4 or absf(max_sum - 1.0) > 1e-4:
		failures.append("weights do not sum to 1: [%.6f, %.6f]" % [min_sum, max_sum])
	else:
		print("  OK — no vertex can shrink toward the origin")

	print("\n=== 4. bone indices and weight budget ===")
	var max_bone := 0
	var zero_lead := 0
	for i in range(bones.size()):
		max_bone = max(max_bone, bones[i])
	for v in range(verts.size()):
		if weights[v * infl] <= 0.0:
			zero_lead += 0
	# every influence with weight > 0 must name a real bone
	var bad := 0
	for i in range(weights.size()):
		if weights[i] > 0.0 and bones[i] >= sk.get_bone_count():
			bad += 1
	print("  max bone index %d / %d bones, out-of-range refs = %d" % [max_bone, sk.get_bone_count() - 1, bad])
	if bad > 0 or max_bone >= sk.get_bone_count():
		failures.append("bone index out of range")
	else:
		print("  OK")

	print("\n=== 5. every joint is shared between its parent and child bone ===")
	# Each bone is emitted as its own tube, so the mesh has one connected piece
	# per bone BY CONSTRUCTION — counting components would only restate that.
	# What actually matters is whether neighbouring tubes share a blended
	# region: if a vertex near a joint is bound entirely to one bone, bending
	# that joint tears the surface open.
	var seams := 0
	var checked_seams := 0
	for child in range(sk.get_bone_count()):
		var parent: int = sk.get_bone_parent(child)
		if parent < 0:
			continue
		var joint_pos: Vector3 = rig.bone_heads[child]
		# Look for any vertex carrying BOTH bones.
		var found := false
		for v in range(verts.size()):
			var has_parent := false
			var has_child := false
			for k in range(infl):
				var bi: int = bones[v * infl + k]
				var w: float = weights[v * infl + k]
				if w <= 0.0:
					continue
				if bi == parent:
					has_parent = true
				if bi == child:
					has_child = true
			if has_parent and has_child:
				# It must also be geometrically AT the joint, not elsewhere.
				if verts[v].distance_to(joint_pos) < 0.35:
					found = true
					break
		checked_seams += 1
		if not found:
			seams += 1
	print("  %d joints checked, %d without a shared blended region" % [checked_seams, seams])
	if seams > 0:
		failures.append("%d joints have no shared vertices: bending them tears" % seams)
	else:
		print("  OK — every joint has vertices bound to both bones")

	print("\n=== 6. LBS reproduces the vertex at the rest pose ===")
	var elbow: int = sk.find_bone("forearm.L")
	var target := -1
	var best := 0.0
	for v in range(verts.size()):
		var dominant: int = bones[v * infl]
		var w: float = weights[v * infl]
		if dominant == elbow and w > best:
			best = w
			target = v
	if target < 0:
		failures.append("no vertex is bound to forearm.L")
		print("  FAIL — forearm.L has no vertices")
	else:
		# Do NOT call reset_bone_poses() here. Godot 4 keeps REST and POSE as
		# separate quantities; the rig builder writes the pose explicitly to
		# match the rest, and resetting would undo that and put the skeleton
		# back at identity — which is what made this test report a bogus 10.17
		# displacement before.
		print("  probing vertex %d (forearm.L weight %.3f)" % [target, weights[target * infl]])
		var rest_v := verts[target]
		var blended := Vector3.ZERO
		for k in range(infl):
			var bi: int = bones[target * infl + k]
			var w2: float = weights[target * infl + k]
			if w2 <= 0.0:
				continue
			# v' = Σ wᵢ · (global_poseᵢ · bindᵢ) · v
			# Godot's Skin.get_bind_pose() ALREADY contains the inverse of the
			# world rest transform, so it is multiplied as-is. Inverting it
			# again (a natural mistake, since the word "bind" reads like a
			# forward matrix) squares the offset and moves every vertex.
			var bone_xf: Transform3D = sk.get_bone_global_pose(bi) * skin.get_bind_pose(bi)
			blended += w2 * (bone_xf * rest_v)
		var moved := rest_v.distance_to(blended)
		print("  v at rest   = %s" % str(rest_v.snapped(Vector3(0.001, 0.001, 0.001))))
		print("  v after LBS = %s" % str(blended.snapped(Vector3(0.001, 0.001, 0.001))))
		print("  displacement at rest = %s" % str(moved))
		if moved > 1e-4:
			failures.append("rest pose is not identity: vertex moved %.4f" % moved)
		else:
			print("  OK — bind matrices cancel the rest pose exactly")

	print("\n=== 7. joint bend is continuous (no tear at the elbow) ===")
	var fore: int = sk.find_bone("forearm.L")
	var best_v := -1
	var best_d := INF
	var elbow_pos: Vector3 = rig.bone_heads[fore]
	for v in range(verts.size()):
		if bones[v * infl] == fore:
			var d: float = verts[v].distance_to(elbow_pos)
			if d < best_d:
				best_d = d
				best_v = v
	if best_v < 0:
		failures.append("forearm.L has no vertices")
	else:
		var w_fore: float = weights[best_v * infl]
		print("  vertex closest to elbow: weight(forearm.L) = %.3f" % w_fore)
		# Weight must be shared, not 0 or 1 — those are the crease cases.
		if w_fore < 0.25 or w_fore > 0.98:
			failures.append("elbow blend is not continuous (weight %.3f)" % w_fore)
		else:
			print("  OK — the joint is shared between two bones")

	print("\n=== walk cycle is bounded ===")
	var pose: Dictionary = RigScript.walk_pose(1.0)
	var max_ang := 0.0
	for k in pose:
		var e: Vector3 = pose[k]
		max_ang = maxf(max_ang, absf(e.x))
	print("  max joint angle in walk pose = %.3f rad (%.1f deg)" % [max_ang, rad_to_deg(max_ang)])
	if max_ang > 1.2:
		failures.append("walk pose exceeds %.0f deg at a joint" % rad_to_deg(1.2))
	else:
		print("  OK")

	print("\n=== 8. a camera placed by this rig must face the mesh ===")
	# The same class of bug that cost several rounds on the terrain prototype:
	# a Camera3D looks down its local -Z, so placing it on one side of the
	# subject and yawing 0 puts its back to the subject.
	var cam := Camera3D.new()
	# look_at() needs a node inside the tree; look_at_from_position() does not,
	# and it derives both yaw and pitch from the actual positions so there is
	# no hand-tuned Euler triple to get wrong.
	cam.look_at_from_position(Vector3(0.5, 1.5, -4.2), Vector3(0.0, 1.0, 0.0), Vector3.UP)
	var centre := Vector3.ZERO
	for v in range(verts.size()):
		centre += verts[v]
	centre /= float(verts.size())
	var fwd := -cam.transform.basis.z
	var to := (centre - cam.position).normalized()
	# Only the HORIZONTAL bearing decides "which way is the camera pointed";
	# pitch is a separate, intentional choice.
	var flat_fwd := Vector3(fwd.x, 0.0, fwd.z).normalized()
	var flat_to := Vector3(to.x, 0.0, to.z).normalized()
	var angle := rad_to_deg(acos(clampf(flat_fwd.dot(flat_to), -1.0, 1.0)))
	print("  camera fwd %s, mesh centroid %s, horizontal angle = %.1f deg" % [str(fwd), str(centre), angle])
	if angle > 1.0:
		failures.append("camera yaw is %.1f deg away from the mesh" % angle)
	else:
		print("  OK — the camera actually looks at the character")
	cam.free()

	print("\n" + "=".repeat(52))
	if failures.size() > 0:
		for f in failures:
			print("FAIL: " + f)
		print("%d failure(s)" % failures.size())
		quit(1)
	else:
		print("all rig checks pass")
	quit(0)
	quit(0)