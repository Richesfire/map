extends Node3D

@export var grass_count: int = 1800
@export var flower_count: int = 90
@export var rock_count: int = 34
@export var area_radius: float = 78.0
@export var rng_seed: int = 20261024

var _rng := RandomNumberGenerator.new()
var _noise := FastNoiseLite.new()

func _ready() -> void:
	_rng.seed = rng_seed
	_noise.seed = rng_seed
	_noise.frequency = 0.032
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_octaves = 2
	_build_grass()
	_build_flowers()
	_build_rocks()

func _build_grass() -> void:
	var mesh := _make_grass_mesh()
	if mesh == null:
		return
	var mat := _make_grass_material()
	var centers: Array[Vector3] = []
	for i in 72:
		var a := _rng.randf() * TAU
		var r := sqrt(_rng.randf()) * area_radius * 0.92
		centers.append(Vector3(cos(a) * r, 0.0, sin(a) * r))

	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for i in grass_count:
		var c: Vector3 = centers[_rng.randi_range(0, centers.size() - 1)]
		var a := _rng.randf() * TAU
		var r := sqrt(_rng.randf()) * 2.2
		var pos := c + Vector3(cos(a) * r, 0.02, sin(a) * r)
		if pos.length() > area_radius:
			continue
		# 噪声让草成片出现，避免均匀铺满
		if _noise.get_noise_2d(pos.x * 0.85, pos.z * 0.85) < -0.28:
			continue
		var s := _rng.randf_range(0.65, 1.35)
		var sy := _rng.randf_range(0.75, 1.35)
		var rot := _rng.randf() * TAU
		var b := Basis(Vector3.UP, rot).scaled(Vector3(s, sy, s))
		transforms.append(Transform3D(b, pos))
		var g := _rng.randf_range(0.82, 1.08)
		colors.append(Color(0.24 * g, 0.34 * g, 0.15 * g, 1.0))
	_make_multimesh("Grass", mesh, mat, transforms, colors, false, 92.0)

func _build_flowers() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 0.06
	mesh.height = 0.14
	mesh.radial_segments = 4
	mesh.rings = 2
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1, 1)
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for i in flower_count:
		var a := _rng.randf() * TAU
		var r := sqrt(_rng.randf()) * area_radius * 0.9
		var pos := Vector3(cos(a) * r, 0.05, sin(a) * r)
		if _noise.get_noise_2d(pos.x * 0.85, pos.z * 0.85) < -0.2:
			continue
		var s := _rng.randf_range(0.7, 1.4)
		transforms.append(Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(s, s, s)), pos))
		var choice := _rng.randi_range(0, 2)
		var col: Color
		if choice == 0:
			col = Color(0.78, 0.74, 0.48, 1)
		elif choice == 1:
			col = Color(0.7, 0.62, 0.74, 1)
		else:
			col = Color(0.82, 0.8, 0.68, 1)
		colors.append(col)
	_make_multimesh("Flowers", mesh, mat, transforms, colors, false, 78.0)

func _build_rocks() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 0.34
	mesh.height = 0.3
	mesh.radial_segments = 5
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.36, 0.35, 0.32, 1)
	mat.roughness = 0.95
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for i in rock_count:
		var a := _rng.randf() * TAU
		var r := sqrt(_rng.randf()) * area_radius * 0.88
		var pos := Vector3(cos(a) * r, 0.08, sin(a) * r)
		var s := _rng.randf_range(0.55, 1.6)
		var b := Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(s * _rng.randf_range(0.9, 1.3), s * 0.7, s))
		transforms.append(Transform3D(b, pos))
		colors.append(Color(0.32 + _rng.randf() * 0.08, 0.31 + _rng.randf() * 0.07, 0.29 + _rng.randf() * 0.06, 1.0))
	_make_multimesh("Rocks", mesh, mat, transforms, colors, true, 120.0)

func _make_multimesh(node_name: String, mesh: Mesh, mat: Material, transforms: Array[Transform3D], colors: Array[Color], cast_shadow: bool, view_distance: float) -> void:
	if transforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, colors[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = view_distance
	add_child(mmi)

func _make_grass_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 3:
		var yaw := float(i) * TAU / 3.0
		var b := Basis(Vector3.UP, yaw)
		var p0 := b * Vector3(-0.11, 0.0, 0.0)
		var p1 := b * Vector3(0.11, 0.0, 0.0)
		var p2 := b * Vector3(0.015, 0.62, 0.04)
		st.add_vertex(p0)
		st.add_vertex(p1)
		st.add_vertex(p2)
	st.generate_normals()
	return st.commit()

func _make_grass_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1, 1)
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return mat
