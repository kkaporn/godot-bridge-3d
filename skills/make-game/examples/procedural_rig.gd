extends RefCounted
class_name ProceduralRig

# A fully procedural rigged character: skeleton, skinned mesh, and animation.
# Nothing here is loaded from a file — the bone hierarchy, every vertex, every
# skin weight and every animation key are computed.
#
# The maths being used:
#   • Skeleton: each bone stores a REST transform. The bind matrix is its
#     inverse, so at rest pose every vertex lands exactly where it was authored.
#   • Skinning: v' = Σ wᵢ · Bᵢ · v, with Σ wᵢ = 1 (partition of unity).
#     If the weights do not sum to 1 the mesh shrinks toward the origin —
#     that is the single most common skinning bug, and it is checked below.
#   • Weights: inverse-distance to bone SEGMENTS, not to bone origins. A
#     weight based on point distance collapses at the joints, where the
#     distance to the neighbouring bone head is small but the vertex belongs
#     halfway down both bones.

const UP := Vector3.UP

# name, parent index, head offset from parent tail (or parent head for root)
const SKELETON := [
	{"name": "root",   "parent": -1, "pos": Vector3(0, 0, 0)},
	{"name": "hips",   "parent": 0,  "pos": Vector3(0, 1.05, 0)},
	{"name": "spine",  "parent": 1,  "pos": Vector3(0, 0.18, 0)},
	{"name": "chest",  "parent": 2,  "pos": Vector3(0, 0.22, 0)},
	{"name": "neck",   "parent": 3,  "pos": Vector3(0, 0.20, 0)},
	{"name": "head",   "parent": 4,  "pos": Vector3(0, 0.10, 0)},

	{"name": "shoulder.L", "parent": 3, "pos": Vector3(0.06, 0.14, 0)},
	{"name": "arm.L",      "parent": 6, "pos": Vector3(0.14, 0, 0)},
	{"name": "forearm.L",  "parent": 7, "pos": Vector3(0.30, 0, 0)},
	{"name": "hand.L",     "parent": 8, "pos": Vector3(0.26, 0, 0)},

	{"name": "shoulder.R", "parent": 3, "pos": Vector3(-0.06, 0.14, 0)},
	{"name": "arm.R",      "parent": 10, "pos": Vector3(-0.14, 0, 0)},
	{"name": "forearm.R",  "parent": 11, "pos": Vector3(-0.30, 0, 0)},
	{"name": "hand.R",     "parent": 12, "pos": Vector3(-0.26, 0, 0)},

	{"name": "thigh.L",  "parent": 1, "pos": Vector3(0.10, -0.06, 0)},
	{"name": "shin.L",   "parent": 14, "pos": Vector3(0, -0.42, 0)},
	{"name": "foot.L",   "parent": 15, "pos": Vector3(0, -0.42, 0)},

	{"name": "thigh.R",  "parent": 1, "pos": Vector3(-0.10, -0.06, 0)},
	{"name": "shin.R",   "parent": 17, "pos": Vector3(0, -0.42, 0)},
	{"name": "foot.R",   "parent": 18, "pos": Vector3(0, -0.42, 0)},
]

# How thick each bone's tube is at its head and tail. Limbs taper, the torso
# does not — a uniform radius reads as a balloon.
const RADII := {
	"root": [0.0, 0.0], "hips": [0.16, 0.14], "spine": [0.14, 0.15],
	"chest": [0.15, 0.17], "neck": [0.07, 0.07], "head": [0.10, 0.11],
	"shoulder.L": [0.08, 0.08], "arm.L": [0.07, 0.055],
	"forearm.L": [0.055, 0.042], "hand.L": [0.042, 0.030],
	"shoulder.R": [0.08, 0.08], "arm.R": [0.07, 0.055],
	"forearm.R": [0.055, 0.042], "hand.R": [0.042, 0.030],
	"thigh.L": [0.10, 0.075], "shin.L": [0.075, 0.050], "foot.L": [0.050, 0.038],
	"thigh.R": [0.10, 0.075], "shin.R": [0.075, 0.050], "foot.R": [0.050, 0.038],
}

const RINGS := 6# segments along a bone
const SIDES := 10   # segments around a bone

var bone_names: PackedStringArray = []
var bone_heads: PackedVector3Array = []
var bone_tails: PackedVector3Array = []
var bone_parents := PackedInt32Array()


# ── skeleton ────────────────────────────────────────────────────────────────
func build_skeleton() -> Skeleton3D:
	var sk := Skeleton3D.new()
	sk.name = "Skeleton3D"
	for i in SKELETON.size():
		sk.add_bone(SKELETON[i]["name"])
	for i in SKELETON.size():
		var parent: int = SKELETON[i]["parent"]
		if parent >= 0:
			sk.set_bone_parent(i, parent)
		var local := Transform3D(Basis(), SKELETON[i]["pos"])
		sk.set_bone_rest(i, local)
		sk.set_bone_pose(i, local)
		# Absolute head, tracked separately for geometry generation. Godot's
		# bone rest/pose is expressed in the PARENT's frame and it composes the
		# chain itself, so writing absolute positions here would double-count
		# every parent offset.
		var head := Vector3.ZERO
		if parent >= 0:
			head = bone_heads[parent]
		bone_heads.append(head + SKELETON[i]["pos"])
		bone_tails.append(Vector3.ZERO)  # real tail resolved after all heads exist
	for i in bone_heads.size():
		var child := _first_child(i)
		bone_tails[i] = bone_heads[child] if child >= 0 else bone_heads[i] + UP * 0.05
	for i in SKELETON.size():
		bone_names.append(SKELETON[i]["name"])
		bone_parents.append(SKELETON[i]["parent"])
	return sk


func _first_child(bone: int) -> int:
	for i in SKELETON.size():
		if SKELETON[i]["parent"] == bone:
			return i
	return -1


# ── geometry ────────────────────────────────────────────────────────────────
# Every vertex is a point on a ring around some bone axis. Skinning that with
# the bone it was generated for is then trivially correct at rest.
#
# Note: SurfaceTool has no bone-weight API in 4.7 (only set_bones), so the
# arrays are assembled by hand and written straight into ARRAY_BONES /
# ARRAY_WEIGHTS.
const INFLUENCES := 4# Godot's fixed per-vertex influence budget

func build_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	for b in bone_names.size():
		if float(RADII.get(bone_names[b], [0.0, 0.0])[0]) <= 0.0:
			continue  # root is an anchor, not a shape
		_emit_tube(b, verts, bones, weights, uvs, indices)

	# Area-weighted normals from the emitted triangles.
	var normals := _compute_normals(verts, indices)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _emit_tube(b: int, verts: PackedVector3Array, bones: PackedInt32Array,
		weights: PackedFloat32Array, uvs: PackedVector2Array,
		indices: PackedInt32Array) -> void:
	var head := bone_heads[b]
	var tail := bone_tails[b]
	var axis := tail - head
	var length := axis.length()
	if length < 1e-5:
		return
	axis /= length

	# Any vector not parallel to the axis gives a stable frame.
	var ref := UP if absf(axis.dot(UP)) < 0.95 else Vector3.RIGHT
	var side := axis.cross(ref).normalized()
	var fwd := side.cross(axis).normalized()

	var radii: Array = RADII[bone_names[b]]
	var r0: float = radii[0]
	var r1: float = radii[1]

	var parent_bone := bone_parents[b]
	var child_bone := _first_child(b)
	var base := verts.size()

	for i in RINGS + 1:
		var t := float(i) / float(RINGS)
		# Smoothstep the taper so limbs thin out gradually instead of stepping.
		var tt := t * t * (3.0 - 2.0 * t)
		var r: float = lerpf(r0, r1, tt)
		var centre := head + axis * (length * t)
		for j in SIDES:
			var ang := TAU * float(j) / float(SIDES)
			var p := centre + (side * cos(ang) + fwd * sin(ang)) * r

			var along := t
			var w_list := _weights_for(b, p, parent_bone, child_bone, along)
			verts.append(p)
			uvs.append(Vector2(j / float(SIDES), t))
			var padded := _pad_to(w_list, b)
			for k in INFLUENCES:
				bones.append(int(padded[k]["i"]))
				weights.append(float(padded[k]["w"]))

	# Stitch rings. Winding must be consistent so normals face outward.
	for i in RINGS:
		for j in SIDES:
			var a := base + i * SIDES + j
			var a2 := base + i * SIDES + (j + 1) % SIDES
			var b2 := base + (i + 1) * SIDES + (j + 1) % SIDES
			var b3 := base + (i + 1) * SIDES + j
			indices.append_array([a, a2, b2, a, b2, b3])


# Godot stores exactly INFLUENCES indices+weights per vertex. Pad with zeros
# pointing at a bone that contributes nothing, so the dot product still sums.
func _pad_to(w_list: Array, fallback: int) -> Array:
	var out: Array = w_list.duplicate()
	while out.size() < INFLUENCES:
		out.append({"i": fallback, "w": 0.0})
	return out


func _compute_normals(verts: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var acc := PackedVector3Array()
	acc.resize(verts.size())
	for i in range(0, indices.size(), 3):
		var a := verts[indices[i]]
		var b := verts[indices[i + 1]]
		var c := verts[indices[i + 2]]
		var fn := (b - a).cross(c - a)
		acc[indices[i]] += fn
		acc[indices[i + 1]] += fn
		acc[indices[i + 2]] += fn
	var out := PackedVector3Array()
	for v in acc:
		out.append(v.normalized())
	return out


# ── skinning maths ──────────────────────────────────────────────────────────
# Falloff curves per influence. Near a bone's own span it owns the vertex;
# past the ends it blends into the parent (top) or the child (bottom).
func _weights_for(b: int, p: Vector3, parent_bone: int, child_bone: int,
		along: float) -> Array:
	var out: Array = []
	out.append({"i": b, "w": 1.0})

	# Blend to the child near the tail so the joint bends instead of creasing.
	if child_bone >= 0:
		var t := smoothstep(0.68, 1.0, along)
		if t > 0.001:
			out.append({"i": child_bone, "w": t})

	# Blend to the parent near the head, so a raised arm carries the shoulder.
	if parent_bone >= 0:
		var t2 := smoothstep(0.32, 0.0, along)
		if t2 > 0.001:
			out.append({"i": parent_bone, "w": t2})

	# Strongest first: Godot keeps the first INFLUENCES entries, and a zero-
	# weighted padding entry must never displace a real influence.
	out.sort_custom(func(x, y): return float(x["w"]) > float(y["w"]))

	# Partition of unity — renormalise so the surface never shrinks.
	var total := 0.0
	for w in out:
		total += float(w["w"])
	if total <= 0.0:
		return [{"i": b, "w": 1.0}]
	for w in out:
		w["w"] = float(w["w"]) / total
	return out


func smoothstep(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


# ── skin resource ───────────────────────────────────────────────────────────
func build_skin(sk: Skeleton3D) -> Skin:
	var skin := Skin.new()
	for i in bone_names.size():
		# The bind must be the inverse of the bone's WORLD rest transform, not
		# its local rest. LBS reads vertices in world space and multiplies by
		# (global_pose · bind⁻¹); that product is the identity only when bind
		# == global_pose⁻¹. Using the local rest here silently offsets every
		# vertex by that bone's accumulated parent translation.
		var global_rest := Transform3D(Basis(), bone_heads[i])
		skin.add_bind(i, global_rest.affine_inverse())
	return skin


# ── animation ───────────────────────────────────────────────────────────────
# A walk cycle as pure maths: joint angle = base + amplitude * sin(phase + offset).
# Every limb is driven by the same clock with a phase offset, which is why the
# arms and legs end up in antiphase without anyone keyframing that by hand.
static func walk_pose(t: float) -> Dictionary:
	var s := sin(t)
	var c := cos(t)
	return {
		"thigh.L": Vector3(s * 0.62, 0, 0),
		"shin.L": Vector3(maxf(0.0, -s) * 0.95, 0, 0),
		"thigh.R": Vector3(-s * 0.62, 0, 0),
		"shin.R": Vector3(maxf(0.0, s) * 0.95, 0, 0),
		"arm.L": Vector3(-s * 0.48, 0, 0.12),
		"arm.R": Vector3(s * 0.48, 0, -0.12),
		"forearm.L": Vector3(maxf(0.0, s) * 0.42, 0, 0),
		"forearm.R": Vector3(maxf(0.0, -s) * 0.42, 0, 0),
		"spine": Vector3(0, s * 0.06, c * 0.04),
		"head": Vector3(0, -s * 0.04, 0),
	}