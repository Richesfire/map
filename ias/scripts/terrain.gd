extends Node3D
## 地形：极坐标 Clipmap + 最终地形（底图 + 山体特征 + 细节噪声）
## 所有高度都向 terrain_gen.gd 取，渲染/碰撞/植被/小地图是同一套数据。

const TG := preload("res://scripts/terrain_gen.gd")
const BiomeLib := preload("res://scripts/biome_library.gd")

const N_THETA := 160
const R_MIN := 6.0
const R_MAX := 90000.0
const Q := 1.062
const COLLIDE_R := 5000.0

const DEM2K_W := 16384
const DEM2K_H := 8192
const DEM_W := 4096
const DEM_H := 2048

var _mesh: MeshInstance3D
var _body: StaticBody3D
var _veg: Node3D
var _city_root: Node3D

var center_lon := 113.72
var center_lat := 36.00


func _ready() -> void:
	TG.ensure_loaded()


# ---------------- 地形真源 ----------------
func dem_at(lon: float, lat: float) -> float:
	TG.ensure_loaded()
	return TG.dem_at(lon, lat)


func lonlat_of(x: float, z: float) -> Vector2:
	return TG.lonlat_of(x, z, center_lon, center_lat)


## 顶点间距（米）：角度间距与径向间距取大者，用来决定细节噪声何时淡出，
## 避免远处出现采样混叠（不是“只在 6km 内有细节”的硬截断）。
func spacing_at(r: float) -> float:
	return maxf(r * TAU / float(N_THETA), r * (Q - 1.0))


func height_xyz(x: float, z: float, spacing: float = -1.0) -> float:
	var ll := lonlat_of(x, z)
	if spacing < 0.0:
		spacing = spacing_at(sqrt(x * x + z * z))
	return TG.height_ll(ll.x, ll.y, spacing)


# ---------------- 网格 ----------------
## 分帧构建：每 12 环让出一帧，加载界面才能转起来、进度条才能动。
func build(progress: Callable = Callable()) -> void:
	if _mesh != null:
		_mesh.queue_free()
		_mesh = null
	if _body != null:
		_body.queue_free()
		_body = null

	var t0 := Time.get_ticks_msec()
	var radii: Array[float] = []
	var r := R_MIN
	while r < R_MAX:
		radii.append(r)
		r *= Q
	radii.append(R_MAX)

	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()

	var b0 := TG.biome_at(center_lon, center_lat, TG.macro_height(center_lon, center_lat))
	var h0 := height_xyz(0, 0, 1.0)
	verts.append(Vector3(0, h0, 0))
	var c0 := TG.biome_color(b0)
	var lf0 := TG.landform_kind(center_lon, center_lat, h0)
	var mat0 := TG.landform_material(center_lon, center_lat)
	cols.append(Color(c0.r, c0.g, c0.b, (float(lf0) + float(mat0) * 32.0) / 64.0))

	var total := radii.size()
	for ri in total:
		var rr: float = radii[ri]
		var sp := spacing_at(rr)
		for j in N_THETA:
			var a := TAU * float(j) / float(N_THETA)
			var x := cos(a) * rr
			var z := sin(a) * rr
			var h := TG.height_xyz(x, z, center_lon, center_lat, sp)
			var ll := lonlat_of(x, z)
			var biome := TG.biome_at(ll.x, ll.y, h)
			var c := TG.biome_color(biome)
			var k := 0.90 + 0.20 * TG._vnoise(x * 0.0025, z * 0.0025, 771)
			var lf := TG.landform_kind(ll.x, ll.y, h)
			var mat := TG.landform_material(ll.x, ll.y)
			verts.append(Vector3(x, h, z))
			cols.append(Color(c.r * k, c.g * k, c.b * k, (float(lf) + float(mat) * 32.0) / 64.0))

		if ri % 12 == 11:
			if progress.is_valid():
				progress.call(0.04 + 0.76 * float(ri + 1) / float(total))
			await get_tree().process_frame

	for j in N_THETA:
		idx.append(0)
		idx.append(1 + j)
		idx.append(1 + ((j + 1) % N_THETA))
	for i in radii.size() - 1:
		var r0 := 1 + i * N_THETA
		var r1 := 1 + (i + 1) * N_THETA
		for j in N_THETA:
			var j2 := (j + 1) % N_THETA
			idx.append(r0 + j)
			idx.append(r1 + j)
			idx.append(r0 + j2)
			idx.append(r0 + j2)
			idx.append(r1 + j)
			idx.append(r1 + j2)

	if progress.is_valid():
		progress.call(0.84)
	await get_tree().process_frame

	# 法线：用网格邻点解析计算（含环形回绕），修接缝与环间明暗带
	var nrms := PackedVector3Array()
	nrms.resize(verts.size())
	nrms[0] = Vector3.UP
	var last_ring := radii.size() - 1
	for i in radii.size():
		var base_idx := 1 + i * N_THETA
		var below := 0 if i == 0 else base_idx - N_THETA
		var above := base_idx + N_THETA if i < last_ring else base_idx
		for j in N_THETA:
			var jp := (j + 1) % N_THETA
			var jm := (j - 1 + N_THETA) % N_THETA
			var dxv := verts[base_idx + jp] - verts[base_idx + jm]
			var dzv := verts[above + j] - verts[below + j]
			var nv := dzv.cross(dxv)
			if nv.length() < 0.0001:
				nv = Vector3.UP
			nv = nv.normalized()
			if nv.y < 0.0:
				nv = -nv
			nrms[base_idx + j] = nv

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in verts.size():
		st.set_color(cols[i])
		st.set_normal(nrms[i])
		st.add_vertex(verts[i])
	for i in idx.size():
		st.add_index(idx[i])
	var mesh := st.commit()
	mesh.surface_set_material(0, _mat())

	_mesh = MeshInstance3D.new()
	_mesh.mesh = mesh
	add_child(_mesh)

	if progress.is_valid():
		progress.call(0.92)
	await get_tree().process_frame

	_build_collision(verts, idx, radii)

	# 手工城市：跟着地形一起重建（位置按当前中心换算）
	if _city_root == null:
		_city_root = load("res://scripts/city.gd").new()
		add_child(_city_root)
	_city_root.rebuild(center_lon, center_lat)

	if progress.is_valid():
		progress.call(1.0)
	print("[地形] 顶点 %d，环 %d，用时 %d ms"
			% [verts.size(), radii.size(), Time.get_ticks_msec() - t0])


## 程序生成 4x4 地表纹理图集（草/枯草/裸土/砾石/岩石/雪/泥…）
static var _atlas_tex: ImageTexture

const ATLAS_TILE := 256
const ATLAS_COLS := [
	Color(0.34, 0.43, 0.21), Color(0.60, 0.55, 0.30), Color(0.22, 0.37, 0.14),
	Color(0.40, 0.32, 0.21), Color(0.50, 0.49, 0.45), Color(0.42, 0.42, 0.40),
	Color(0.52, 0.48, 0.42), Color(0.72, 0.66, 0.46), Color(0.85, 0.87, 0.89),
	Color(0.28, 0.24, 0.17), Color(0.28, 0.40, 0.20), Color(0.48, 0.40, 0.28),
	Color(0.54, 0.40, 0.28), Color(0.56, 0.52, 0.28), Color(0.24, 0.28, 0.14),
	Color(0.70, 0.66, 0.52),
]


func _make_atlas() -> ImageTexture:
	if _atlas_tex != null:
		return _atlas_tex
	# 优先加载 CC0 真实贴图图集（data/textures/ground_atlas.png）
	var real: Image = Image.load_from_file("res://data/textures/ground_atlas.png")
	if real != null and not real.is_empty():
		real.generate_mipmaps()
		_atlas_tex = ImageTexture.create_from_image(real)
		print("[地形] 使用真实贴图图集 %dx%d" % [real.get_width(), real.get_height()])
		return _atlas_tex
	var n := FastNoiseLite.new()
	n.frequency = 0.02
	n.fractal_octaves = 5
	n.fractal_gain = 0.55
	var fine := FastNoiseLite.new()
	fine.frequency = 0.16
	fine.fractal_octaves = 3
	var streak := FastNoiseLite.new()
	streak.frequency = 0.05
	streak.fractal_octaves = 2

	var size := ATLAS_TILE * 4
	var buf := PackedByteArray()
	buf.resize(size * size * 3)
	for k in 16:
		var ox := (k % 4) * ATLAS_TILE
		var oy := (k / 4) * ATLAS_TILE
		var base: Color = ATLAS_COLS[k]
		var amp := 0.11
		if k == 4 or k == 5 or k == 6:
			amp = 0.20
		elif k == 8:
			amp = 0.05
		elif k == 9:
			amp = 0.16
		elif k == 7:
			amp = 0.09
		var grassy := (k == 0 or k == 1 or k == 2 or k == 13 or k == 14)
		var rocky := (k == 4 or k == 5 or k == 6 or k == 11)
		var sandy := (k == 7 or k == 15)
		for y in ATLAS_TILE:
			for x in ATLAS_TILE:
				var fx := float(ox + x)
				var fy := float(oy + y)
				var v := n.get_noise_2d(fx, fy) * 0.5 + 0.5
				var g := fine.get_noise_2d(fx * 1.6, fy * 1.6) * 0.5 + 0.5
				var fold := 1.0 + (v - 0.5) * amp * 2.0 + (g - 0.5) * 0.10

				# 结构层：不同地貌的纹理要有“形态”，不能只是噪声
				if grassy:
					# 草叶走向：沿一个方向拉长的条带
					var s := streak.get_noise_2d(fx * 0.6, fy * 3.2) * 0.5 + 0.5
					fold *= 0.88 + 0.30 * s
					fold *= 1.0 - 0.10 * smoothstep(0.55, 0.75, g)
				elif rocky:
					# 岩石：脊状裂纹
					var r := absf(streak.get_noise_2d(fx * 1.1, fy * 1.1))
					fold *= 1.0 - 0.18 * (1.0 - smoothstep(0.0, 0.16, r))
					fold *= 0.94 + 0.18 * g
				elif sandy:
					# 沙：横向波痕
					fold *= 0.94 + 0.12 * sin(fy * 0.55 + v * 6.0)
				elif k == 8:
					# 雪：柔和团块
					fold *= 0.96 + 0.10 * g
				elif k == 9:
					# 泥地：斑驳水洼
					fold *= 0.85 + 0.30 * smoothstep(0.45, 0.7, v)
				var i := ((oy + y) * size + (ox + x)) * 3
				buf[i] = int(clampf(base.r * fold, 0.0, 1.0) * 255.0)
				buf[i + 1] = int(clampf(base.g * fold, 0.0, 1.0) * 255.0)
				buf[i + 2] = int(clampf(base.b * fold, 0.0, 1.0) * 255.0)
	var img := Image.create_from_data(size, size, false, Image.FORMAT_RGB8, buf)
	img.generate_mipmaps()
	_atlas_tex = ImageTexture.create_from_image(img)
	print("[地形] 地表纹理图集 %dx%d（16 张 256px）" % [size, size])
	return _atlas_tex


func _mat() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/terrain.gdshader")
	m.set_shader_parameter("ground_atlas", _make_atlas())
	var nrm: Image = Image.load_from_file("res://data/textures/ground_normal.png")
	if nrm != null and not nrm.is_empty():
		m.set_shader_parameter("ground_normal", ImageTexture.create_from_image(nrm))
	m.set_shader_parameter("tex_scale", 0.075)
	var n := FastNoiseLite.new()
	n.frequency = 0.32
	n.fractal_octaves = 4
	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 512
	tex.seamless = true
	tex.generate_mipmaps = true
	tex.noise = n
	m.set_shader_parameter("noise_tex", tex)
	return m


## 只给 COLLIDE_R 内的顶点建碰撞（凹三角网），与渲染顶点完全同一批数据
func _build_collision(verts: PackedVector3Array, idx: PackedInt32Array, radii: Array) -> void:
	var max_ring := 0
	for i in radii.size():
		if float(radii[i]) <= COLLIDE_R:
			max_ring = i + 1

	var vs := PackedVector3Array()
	var cidxs := PackedInt32Array()
	var remap := {}
	for i in idx.size():
		var vi: int = idx[i]
		if vi > max_ring * N_THETA:
			continue
		if not remap.has(vi):
			remap[vi] = vs.size()
			vs.append(verts[vi])
		cidxs.append(remap[vi])

	if cidxs.is_empty():
		return

	var cmesh := ArrayMesh.new()
	var carr := []
	carr.resize(Mesh.ARRAY_MAX)
	carr[Mesh.ARRAY_VERTEX] = vs
	carr[Mesh.ARRAY_INDEX] = cidxs
	cmesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, carr)

	_body = StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = cmesh.create_trimesh_shape()
	_body.add_child(cs)
	add_child(_body)
	print("[地形] 碰撞三角面 %d" % (cidxs.size() / 3))


## 植被：按地貌密度撒点（森林密、草原稀、荒漠几乎没有），颜色随地貌变化
## 找 assets/trees 下的 glb：有就用写实模型，没有退回程序化树
func _find_mesh_node(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return n as MeshInstance3D
	for c in n.get_children():
		var r := _find_mesh_node(c)
		if r != null:
			return r
	return null


func _load_tree_assets() -> Array:
	var out: Array = []
	var dir := DirAccess.open("res://assets/trees")
	if dir == null:
		return out
	for f in dir.get_files():
		if not (f.ends_with(".glb") or f.ends_with(".gltf")):
			continue
		var ps: PackedScene = load("res://assets/trees/" + f)
		if ps == null:
			continue
		var inst: Node = ps.instantiate()
		var mi := _find_mesh_node(inst)
		if mi != null and mi.mesh != null:
			out.append(mi.mesh)
		inst.free()
	if not out.is_empty():
		print("[植被] 使用写实树模型 %d 个（assets/trees）" % out.size())
	return out


## 草丛贴图（程序生成，RGBA，带 alpha）
static var _grass_tex: ImageTexture


func _make_grass_tex() -> ImageTexture:
	if _grass_tex != null:
		return _grass_tex
	var real: Image = Image.load_from_file("res://data/textures/grass_sheet.png")
	if real != null and not real.is_empty():
		real.generate_mipmaps()
		_grass_tex = ImageTexture.create_from_image(real)
		print("[植被] 使用真实草叶图集")
		return _grass_tex
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	# 20 根叶片
	for b in 52:
		var x0 := rng.randf_range(0.12, 0.88) * n
		var h := rng.randf_range(0.45, 0.95) * n
		var lean := rng.randf_range(-0.18, 0.18) * n
		var w := rng.randf_range(1.6, 3.4)
		var col := Color(0.34 + rng.randf() * 0.20, 0.50 + rng.randf() * 0.18, 0.18 + rng.randf() * 0.12)
		for yy in int(h):
			var tt := float(yy) / h
			var cx := x0 + lean * tt * tt
			var ww := w * (1.0 - tt * 0.85)
			for xx in int(maxf(ww, 1.0)):
				var px := int(cx + float(xx) - ww * 0.5)
				var py := n - 1 - yy
				if px >= 0 and px < n and py >= 0 and py < n:
					var a := 1.0 - tt * 0.25
					img.set_pixel(px, py, Color(col.r, col.g, col.b, a))
	img.generate_mipmaps()
	_grass_tex = ImageTexture.create_from_image(img)
	return _grass_tex


## 十字交叉面片（底边在原点）
func _make_grass_card() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := 0.55
	var h := 0.58
	for k in 2:
		var a := float(k) * PI * 0.5
		var dx := cos(a) * w
		var dz := sin(a) * w
		st.set_uv(Vector2(0, 1))
		st.add_vertex(Vector3(-dx, 0, -dz))
		st.set_uv(Vector2(1, 1))
		st.add_vertex(Vector3(dx, 0, dz))
		st.set_uv(Vector2(1, 0))
		st.add_vertex(Vector3(dx, h, dz))
		st.set_uv(Vector2(0, 1))
		st.add_vertex(Vector3(-dx, 0, -dz))
		st.set_uv(Vector2(1, 0))
		st.add_vertex(Vector3(dx, h, dz))
		st.set_uv(Vector2(0, 0))
		st.add_vertex(Vector3(-dx, h, -dz))
	st.generate_normals()
	return st.commit()


## 通用撒点：按地貌配置的密度撒一类杂物
func _scatter_props(mesh: Mesh, target: int, radius: float, seed_i: int,
		smin: float, smax: float, tint: Color, key: String,
		mat: Material = null) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = target
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	var placed := 0
	var guard := 0
	while placed < target and guard < target * 6:
		guard += 1
		var ang := rng.randf() * TAU
		var rad := sqrt(rng.randf()) * radius
		var x := cos(ang) * rad
		var z := sin(ang) * rad
		var ll := lonlat_of(x, z)
		if TG.city_blend(ll.x, ll.y).x > 0.3:
			continue
		# 便宜的高度先判地貌，通过后再算精确高度
		var hr := TG.dem_at(ll.x, ll.y)
		var kind := TG.landform_kind(ll.x, ll.y, hr)
		var prof: Dictionary = TG.BiomeLib.profile_for(kind)
		var dens: float = float(prof.get(key, 0.0))
		# 距离衰减：近处密、远处疏，最外圈基本没有（杂物 LOD）
		dens *= clampf(1.0 - (rad / radius) * 0.75, 0.2, 1.0)
		# 密度遮罩：低频噪声形成成片的疏密区
		var mask := TG._vnoise(ll.x * 6.5 + 11.0, ll.y * 6.5 - 7.0, 5150)
		dens *= 0.25 + 1.5 * mask * mask
		if dens <= 0.001 or rng.randf() > dens:
			continue
		var h := TG.height_xyz(x, z, center_lon, center_lat, spacing_at(rad))
		var s := rng.randf_range(smin, smax)
		var tr := Transform3D()
		tr = tr.scaled(Vector3(s, s * rng.randf_range(0.85, 1.25), s))
		tr = tr.rotated(Vector3.UP, rng.randf() * TAU)
		tr.origin = Vector3(x, h, z)
		mm.set_instance_transform(placed, tr)
		var k := rng.randf_range(0.85, 1.15)
		mm.set_instance_color(placed, Color(tint.r * k, tint.g * k, tint.b * k))
		placed += 1
	mm.instance_count = placed
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	if mat == null:
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.roughness = 0.95
		node.material_override = m
	else:
		node.material_override = mat
	return node


## 灌木：三团错落的球
func _make_shrub() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var offs := [Vector3(0, 0.55, 0), Vector3(0.55, 0.40, 0.2), Vector3(-0.45, 0.45, -0.3)]
	var sizes := [0.62, 0.46, 0.40]
	for i in 3:
		var s := SphereMesh.new()
		s.radius = float(sizes[i])
		s.height = float(sizes[i]) * 1.5
		s.radial_segments = 7
		s.rings = 3
		st.append_from(s, 0, Transform3D(Basis(), offs[i]))
	st.generate_normals()
	return st.commit()


## 岩石：球体顶点做噪声位移
func _make_rock() -> ArrayMesh:
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 1.25
	sm.radial_segments = 7
	sm.rings = 4
	var arr := sm.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	for i in verts.size():
		var v := verts[i]
		var d := 0.62 + 0.55 * absf(TG._vnoise(v.x * 2.1 + 7.0, v.z * 2.1 - 3.0, 91))
		verts[i] = v.normalized() * d
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in idx.size():
		st.add_vertex(verts[idx[i]])
	st.generate_normals()
	return st.commit()


## 石芽/风蚀柱：上细下粗的锥柱，带噪声
func _make_spire(ratio: float, seed_i: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 6
	var levels := 5
	for li in levels:
		var y0 := float(li) / float(levels)
		var y1 := float(li + 1) / float(levels)
		var r0 := (1.0 - y0 * 0.85) * 0.5
		var r1 := (1.0 - y1 * 0.85) * 0.5
		for s in seg:
			var a0 := TAU * float(s) / float(seg)
			var a1 := TAU * float(s + 1) / float(seg)
			var n := 0.82 + 0.36 * TG._vnoise(float(li) * 1.7, float(s) * 0.9, seed_i)
			var p00 := Vector3(cos(a0) * r0 * n, y0, sin(a0) * r0 * n)
			var p01 := Vector3(cos(a1) * r0 * n, y0, sin(a1) * r0 * n)
			var p10 := Vector3(cos(a0) * r1 * n, y1, sin(a0) * r1 * n)
			var p11 := Vector3(cos(a1) * r1 * n, y1, sin(a1) * r1 * n)
			st.add_vertex(p00)
			st.add_vertex(p11)
			st.add_vertex(p10)
			st.add_vertex(p00)
			st.add_vertex(p01)
			st.add_vertex(p11)
	st.generate_normals()
	return st.commit()


## 芦苇：几根细长片
func _make_reeds() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 515
	for i in 7:
		var a := rng.randf() * TAU
		var r := rng.randf() * 0.25
		var bx := cos(a) * r
		var bz := sin(a) * r
		var h := 0.9 + rng.randf() * 0.8
		var w := 0.035
		var lean := (rng.randf() - 0.5) * 0.3
		st.add_vertex(Vector3(bx - w, 0.0, bz))
		st.add_vertex(Vector3(bx + w, 0.0, bz))
		st.add_vertex(Vector3(bx + lean, h, bz))
		st.add_vertex(Vector3(bx - w, 0.0, bz))
		st.add_vertex(Vector3(bx + lean, h, bz))
		st.add_vertex(Vector3(bx - w + lean, h, bz))
	st.generate_normals()
	return st.commit()


## 只在该地貌自己的区域撒专属杂物
func _scatter_special(mesh: Mesh, target: int, radius: float, seed_i: int,
		smin: float, smax: float, tint: Color, kind: int, match_lf: int) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = target
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	var placed := 0
	var guard := 0
	while placed < target and guard < target * 5:
		guard += 1
		var ang := rng.randf() * TAU
		var rad := sqrt(rng.randf()) * radius
		var x := cos(ang) * rad
		var z := sin(ang) * rad
		var ll := lonlat_of(x, z)
		if TG.city_blend(ll.x, ll.y).x > 0.3:
			continue
		var hr := TG.dem_at(ll.x, ll.y)
		if TG.landform_kind(ll.x, ll.y, hr) != match_lf:
			continue
		var prof: Dictionary = TG.BiomeLib.profile_for(match_lf)
		if int(prof.get("special_kind", 0)) != kind:
			continue
		if rng.randf() > float(prof.get("special_density", 0.0)):
			continue
		var h := TG.height_xyz(x, z, center_lon, center_lat, spacing_at(rad))
		var s := rng.randf_range(smin, smax)
		var tr := Transform3D()
		tr = tr.scaled(Vector3(s, s * rng.randf_range(0.8, 1.35), s))
		tr = tr.rotated(Vector3.UP, rng.randf() * TAU)
		tr.origin = Vector3(x, h - 0.1, z)
		mm.set_instance_transform(placed, tr)
		var k := rng.randf_range(0.85, 1.15)
		mm.set_instance_color(placed, Color(tint.r * k, tint.g * k, tint.b * k))
		placed += 1
	mm.instance_count = placed
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	node.material_override = mat
	print("[杂物] 专属 %d 号 放了 %d 个（守卫 %d 次）" % [kind, placed, guard])
	return node


func _build_props() -> void:
	if _veg == null:
		return
	# 草丛
	var gm: Mesh = _make_grass_card()
	var gsh: Shader = load("res://shaders/grass.gdshader")
	var gmat := ShaderMaterial.new()
	if gsh != null:
		gmat.shader = gsh
		gmat.set_shader_parameter("albedo_tex", _make_grass_tex())
		gmat.set_shader_parameter("tint", Color(1.0, 1.0, 1.0))
		gmat.set_shader_parameter("wind_strength", 1.0)
	var sm: Mesh = _make_shrub()
	var rm: Mesh = _make_rock()

	var base := TG.biome_color(TG.biome_at(center_lon, center_lat, height_xyz(0, 0)))
	_veg.add_child(_scatter_props(gm, 16000, 170.0, 7001, 0.8, 1.5,
			Color(0.90, 1.0, 0.80), "grass", gmat))
	_veg.add_child(_scatter_props(sm, 2600, 600.0, 7002, 0.7, 1.6,
			Color(0.20, 0.30, 0.14), "shrub"))
	_veg.add_child(_scatter_props(rm, 1400, 1200.0, 7003, 0.35, 1.1,
			Color(0.42, 0.41, 0.38), "rock"))

	# 各地貌的专属杂物（石芽 / 风蚀柱 / 土柱 / 漂砾 / 芦苇）
	var spire_a := _make_spire(1.0, 331)
	var spire_b := _make_spire(1.4, 332)
	var reeds := _make_reeds()
	var boulder := _make_rock()
	var specials := [
		[12, spire_a, Color(0.56, 0.54, 0.50), 900.0, 0.7, 2.4, 1],   # 喀斯特石芽
		[13, spire_b, Color(0.60, 0.48, 0.36), 1100.0, 1.2, 3.6, 2],  # 雅丹风蚀柱
		[14, spire_a, Color(0.58, 0.47, 0.33), 900.0, 0.6, 2.0, 3],   # 黄土土柱
		[2, boulder, Color(0.46, 0.45, 0.43), 1000.0, 0.8, 2.8, 4],   # 山地漂砾
		[16, boulder, Color(0.50, 0.52, 0.54), 1000.0, 1.0, 3.4, 4],  # 冰川漂砾
		[17, reeds, Color(0.34, 0.42, 0.20), 260.0, 0.8, 1.4, 5],     # 三角洲芦苇
	]
	for sp in specials:
		var match_lf: int = sp[0]
		var mesh: Mesh = sp[1]
		var col: Color = sp[2]
		var rad: float = sp[3]
		_veg.add_child(_scatter_special(mesh, 350, rad, 7100 + match_lf, float(sp[4]), float(sp[5]), col, int(sp[6]), match_lf))
	print("[植被] 杂物：草/灌木/岩石 已撒")


## 树用图集：左半树皮、右半叶片（RGBA）
static var _tree_tex: ImageTexture


func _make_tree_tex() -> ImageTexture:
	if _tree_tex != null:
		return _tree_tex
	var real: Image = Image.load_from_file("res://data/textures/tree_atlas.png")
	if real != null and not real.is_empty():
		real.generate_mipmaps()
		_tree_tex = ImageTexture.create_from_image(real)
		print("[植被] 使用真实树皮/树叶图集 %dx%d" % [real.get_width(), real.get_height()])
		return _tree_tex
	var w := 512
	var h := 256
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 9911
	# 左半：树皮
	for y in h:
		for x in 256:
			var v := 0.30 + 0.16 * TG._vnoise(float(x) * 0.09, float(y) * 0.03, 313)
			var crack := TG._vnoise(float(x) * 0.35, float(y) * 0.06, 314)
			var k := v * (0.75 + 0.45 * crack)
			img.set_pixel(x, y, Color(k * 1.05, k * 0.86, k * 0.62, 1.0))
	# 右半：叶片团（alpha）
	for i in 220:
		var cx := 256.0 + rng.randf() * 250.0
		var cy := rng.randf() * 250.0
		var rr := 6.0 + rng.randf() * 16.0
		var g := 0.22 + rng.randf() * 0.28
		var col := Color(g * 0.72, g * 1.05, g * 0.55, 1.0)
		for yy in range(int(cy - rr), int(cy + rr) + 1):
			for xx in range(int(cx - rr), int(cx + rr) + 1):
				if xx < 256 or xx >= w or yy < 0 or yy >= h:
					continue
				var d := Vector2(float(xx) - cx, float(yy) - cy).length()
				if d < rr * (0.75 + 0.35 * TG._vnoise(float(xx) * 0.2, float(yy) * 0.2, 315)):
					var a := 1.0 - clampf((d / rr - 0.7) / 0.3, 0.0, 1.0)
					if a > 0.25:
						img.set_pixel(xx, yy, Color(col.r, col.g, col.b, 1.0))
	img.generate_mipmaps()
	_tree_tex = ImageTexture.create_from_image(img)
	return _tree_tex


## 一片叶卡（两侧各一张）
func _add_leaf_card(st: SurfaceTool, center: Vector3, size: float, yaw: float, tilt: float) -> void:
	var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, tilt)
	var hw := size * 0.5
	for s in 2:
		var b := basis * Basis(Vector3.UP, float(s) * PI * 0.5)
		var p0 := center - b * Vector3(hw, hw, 0.0)
		var p1 := center - b * Vector3(-hw, hw, 0.0)
		var p2 := center - b * Vector3(-hw, -hw, 0.0)
		var p3 := center - b * Vector3(hw, -hw, 0.0)
		var uv0 := Vector2(0.0, 0.0)
		var uv1 := Vector2(1.0, 0.0)
		var uv2 := Vector2(1.0, 1.0)
		var uv3 := Vector2(0.0, 1.0)
		st.set_uv(uv0)
		st.add_vertex(p0)
		st.set_uv(uv1)
		st.add_vertex(p1)
		st.set_uv(uv2)
		st.add_vertex(p2)
		st.set_uv(uv0)
		st.add_vertex(p0)
		st.set_uv(uv2)
		st.add_vertex(p2)
		st.set_uv(uv3)
		st.add_vertex(p3)


## 叶冠：一圈随机朝向的叶卡，装在椭球里
func _make_leaf_canopy(count: int, s0: float, s1: float, seed_i: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	for i in count:
		var a := rng.randf() * TAU
		var rr := sqrt(rng.randf()) * 1.95
		var y := 3.4 + rng.randf() * 2.6
		var center := Vector3(cos(a) * rr, y, sin(a) * rr)
		# 每片叶簇一点色差，避免一片死绿
		var k := 0.90 + rng.randf() * 0.22
		st.set_color(Color(k, k * 1.02, k * 0.92))
		_add_leaf_card(st, center, s0 + rng.randf() * (s1 - s0),
				rng.randf() * TAU, (rng.randf() - 0.5) * 1.2)
	st.generate_normals()
	return st.commit()


## 三种树形：0 针叶 1 阔叶 2 伞状（含树干）
func _make_species(kind: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.16
	trunk.bottom_radius = 0.30
	trunk.height = 3.2
	trunk.radial_segments = 6
	st.append_from(trunk, 0, Transform3D(Basis(), Vector3(0, 1.6, 0)))
	if kind == 0:
		# 针叶：五层锥，越往上越小
		for k in 5:
			var c := CylinderMesh.new()
			c.top_radius = 0.0
			c.bottom_radius = 1.75 - float(k) * 0.28
			c.height = 2.0
			c.radial_segments = 7
			st.append_from(c, 0, Transform3D(Basis(), Vector3(0, 2.5 + float(k) * 1.05, 0)))
	elif kind == 1:
		# 阔叶：只有主干 + 三根枝条，树冠由叶卡单独承担
		for k in 3:
			var br := CylinderMesh.new()
			br.top_radius = 0.04
			br.bottom_radius = 0.13
			br.height = 2.6
			br.radial_segments = 4
			var ang := float(k) * TAU / 3.0 + 0.5
			var b := Basis(Vector3.UP, ang) * Basis(Vector3.RIGHT, 0.50)
			st.append_from(br, 0, Transform3D(b, Vector3(cos(ang) * 0.32, 3.2, sin(ang) * 0.32)))
	else:
		var s2 := SphereMesh.new()
		s2.radius = 2.8
		s2.height = 1.5
		s2.radial_segments = 9
		s2.rings = 4
		st.append_from(s2, 0, Transform3D(Basis(), Vector3(0, 5.6, 0)))
	st.generate_normals()
	return st.commit()


func _build_vegetation() -> void:
	if _veg != null:
		_veg.queue_free()
		_veg = null

	if TG.city_blend(center_lon, center_lat).x > 0.95:
		print("[植被] 城区内，跳过")
		return

	var assets := _load_tree_assets()
	var use_assets := assets.size() > 0
	var species: Array[Mesh] = []
	for k in 3:
		if use_assets:
			species.append(assets[mini(k, assets.size() - 1)])
		else:
			species.append(_make_species(k))
	var norms: Array[float] = [1.0, 1.0, 1.0]
	if use_assets:
		for k in 3:
			norms[k] = 11.0 / maxf((species[k] as Mesh).get_aabb().size.y, 0.5)

	var mms: Array[MultiMesh] = []
	for k in 3:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = species[k]
		mm.instance_count = 7000
		mms.append(mm)
	var counts := [0, 0, 0]

	var mm_leaf := MultiMesh.new()
	mm_leaf.transform_format = MultiMesh.TRANSFORM_3D
	mm_leaf.use_colors = true
	mm_leaf.mesh = _make_leaf_canopy(44, 1.05, 2.0, 771)
	mm_leaf.instance_count = 7000

	var mm_leaf_far := MultiMesh.new()
	mm_leaf_far.transform_format = MultiMesh.TRANSFORM_3D
	mm_leaf_far.use_colors = true
	mm_leaf_far.mesh = _make_leaf_canopy(10, 2.2, 3.4, 772)
	mm_leaf_far.instance_count = 7000
	var counts_far := [0]

	var rng := RandomNumberGenerator.new()
	rng.seed = 20290
	var guard := 0
	var radius := 2600.0
	var count := 11000
	while counts[0] + counts[1] + counts[2] < count and guard < 40000:
		guard += 1
		var ang := rng.randf() * TAU
		var rad := sqrt(rng.randf()) * radius
		var x := cos(ang) * rad
		var z := sin(ang) * rad
		var ll := lonlat_of(x, z)
		if TG.city_blend(ll.x, ll.y).x > 0.3:
			continue
		var h_rough := TG.dem_at(ll.x, ll.y)
		var biome := TG.biome_at(ll.x, ll.y, h_rough)
		var density := TG.tree_density(biome)
		if density <= 0.0 or rng.randf() > density:
			continue
		# 按距离稀疏：近处密、远处疏（杂物/树木的 LOD）
		var lod := clampf(1.0 - rad / radius * 0.55, 0.45, 1.0)
		if rng.randf() > lod:
			continue
		var h := TG.height_xyz(x, z, center_lon, center_lat, spacing_at(rad))

		# 树种：冷/高山针叶，干燥伞状，其余阔叶
		var sp := 1
		if TG.is_conifer(biome):
			sp = 0
		elif density < 0.45:
			sp = 2

		var sc := (0.85 + rng.randf() * 0.7) * (0.75 + 0.5 * density)
		var nrm: float = norms[sp]
		var tr := Transform3D()
		tr = tr.scaled(Vector3(sc * nrm, sc * nrm * (0.9 + rng.randf() * 0.5), sc * nrm))
		tr = tr.rotated(Vector3.UP, rng.randf() * TAU)
		tr.origin = Vector3(x, h - 0.2, z)
		var idx: int = counts[sp]
		if idx < mms[sp].instance_count:
			mms[sp].set_instance_transform(idx, tr)
			var base: Color = TG.biome_color(biome)
			var tc := Color(base.r * 0.72, base.g * 0.78, base.b * 0.62)
			mms[sp].set_instance_color(idx, tc)
			if sp == 1:
				if rad < 380.0:
					if idx < mm_leaf.instance_count:
						mm_leaf.set_instance_transform(idx, tr)
						mm_leaf.set_instance_color(idx, Color(1, 1, 1))
				else:
					var fi: int = counts_far[0]
					if fi < mm_leaf_far.instance_count:
						mm_leaf_far.set_instance_transform(fi, tr)
						mm_leaf_far.set_instance_color(fi, Color(1, 1, 1))
						counts_far[0] = fi + 1
			counts[sp] = idx + 1

	_veg = Node3D.new()
	var tsh: Shader = load("res://shaders/tree.gdshader")
	var mat_leaf := ShaderMaterial.new()
	var mat_plain := ShaderMaterial.new()
	if tsh != null:
		mat_leaf.shader = tsh
		mat_leaf.set_shader_parameter("wind_strength", 1.0)
		mat_leaf.set_shader_parameter("use_tex", true)
		mat_leaf.set_shader_parameter("albedo_tex", _make_tree_tex())
		mat_plain.shader = tsh
		mat_plain.set_shader_parameter("wind_strength", 1.0)
		mat_plain.set_shader_parameter("use_tex", true)
		mat_plain.set_shader_parameter("mode", 0)
		mat_plain.set_shader_parameter("albedo_tex", _make_tree_tex())
		mat_leaf.set_shader_parameter("mode", 1)
	for k in 3:
		mms[k].instance_count = counts[k]
		if counts[k] == 0:
			continue
		var node := MultiMeshInstance3D.new()
		node.multimesh = mms[k]
		node.material_override = mat_plain
		_veg.add_child(node)

	if counts[1] > 0:
		mm_leaf.instance_count = counts[1]
		var lnode := MultiMeshInstance3D.new()
		lnode.multimesh = mm_leaf
		lnode.material_override = mat_leaf
		_veg.add_child(lnode)
	if counts_far[0] > 0:
		mm_leaf_far.instance_count = counts_far[0]
		var fnode := MultiMeshInstance3D.new()
		fnode.multimesh = mm_leaf_far
		fnode.material_override = mat_leaf
		_veg.add_child(fnode)
	add_child(_veg)
	print("[植被] %d 棵（针叶 %d / 阔叶 %d / 伞状 %d）"
			% [counts[0] + counts[1] + counts[2], counts[0], counts[1], counts[2]])
	_build_props()
