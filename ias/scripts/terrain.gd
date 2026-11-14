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
## 分帧构建：按**时间预算**让帧（每帧 ≤ BUILD_FRAME_MS），加载界面才能一直 60 fps。
## 以前是“每 12 环让一帧”，一帧干 130–150 ms 的活，加载条一顿一顿。
const BUILD_FRAME_MS := 16


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
	var pid := PackedInt32Array()      # 每顶点的地貌包号：lf + mat*32
	var pid2 := PackedInt32Array()     # 过渡用的第二个包号（与 pid 构成规范对）
	var wgt := PackedFloat32Array()    # 两套贴图的混合权重

	var b0 := TG.biome_at(center_lon, center_lat, TG.macro_height(center_lon, center_lat))
	var h0 := height_xyz(0, 0, 1.0)
	verts.append(Vector3(0, h0, 0))
	var c0 := TG.biome_color(b0)
	var lf0 := TG.landform_kind(center_lon, center_lat, h0)
	var mat0 := TG.landform_material(center_lon, center_lat)
	pid.append(lf0 + mat0 * 32)
	cols.append(Color(c0.r, c0.g, c0.b, 0.0))

	var total := radii.size()
	var _frame_t0 := Time.get_ticks_msec()
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
			pid.append(lf + mat * 32)
			verts.append(Vector3(x, h, z))
			cols.append(Color(c.r * k, c.g * k, c.b * k, 0.0))

		if progress.is_valid():
			progress.call(0.04 + 0.76 * float(ri + 1) / float(total))
		# 时间预算让帧：这一环干完后如果已经超预算，就交还一帧
		if Time.get_ticks_msec() - _frame_t0 >= BUILD_FRAME_MS:
			_frame_t0 = Time.get_ticks_msec()
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
	# —— 双套贴图混合：给每个顶点找“相邻的第二个地貌”，用规范对 (min,max) + 权重。
	#    相邻顶点的包号都取 min/max，插值时才不会串到第三个类别。
	var ring_last := radii.size() - 1
	pid2.resize(verts.size())
	wgt.resize(verts.size())
	pid2[0] = pid[0]
	wgt[0] = 0.0
	for i in total:
		var base_v := 1 + i * N_THETA
		for j in N_THETA:
			var v := base_v + j
			var own: int = pid[v]
			var jm := (j - 1 + N_THETA) % N_THETA
			var jp := (j + 1) % N_THETA
			var inn := 0 if i == 0 else base_v - N_THETA + j
			var out := v if i == ring_last else base_v + N_THETA + j
			var nb := [pid[base_v + jm], pid[base_v + jp], pid[inn], pid[out]]
			var other := -1
			var best := 0
			for k in 4:
				var val: int = nb[k]
				if val == own:
					continue
				var cnt := 0
				for t in 4:
					if nb[t] == val:
						cnt += 1
				if cnt > best:
					best = cnt
					other = val
			var w := 0.0
			var a_lo := own
			var b_hi := own
			if other >= 0 and best > 0:
				a_lo = mini(own, other)
				b_hi = maxi(own, other)
				var t := clampf(float(best) / 4.0, 0.0, 0.75)
				w = t if own < other else 1.0 - t
			pid[v] = a_lo
			pid2[v] = b_hi
			wgt[v] = w

	var uv2 := PackedVector2Array()
	uv2.resize(verts.size())
	for i in verts.size():
		var c := cols[i]
		cols[i] = Color(c.r, c.g, c.b, float(pid[i]) / 128.0)
		uv2[i] = Vector2(float(pid2[i]) / 128.0, wgt[i])

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
		st.set_uv2(uv2[i])
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


## 地貌 → 4 张地表贴图（图集 4x4 索引 t0..t3）。原来这张表写在地形着色器的
## 29 段 if 链里，改到 GDScript 后着色器只查表，双套贴图混合同一张表也就够了。
const LF_TILES := {
	0: [0, 2, 1, 3], 1: [0, 2, 3, 3], 2: [5, 6, 11, 3], 3: [1, 3, 0, 2],
	4: [0, 3, 1, 2], 5: [2, 9, 0, 3], 6: [7, 3, 4, 11], 7: [1, 13, 0, 3],
	8: [14, 2, 3, 10], 9: [9, 10, 2, 3], 10: [8, 5, 6, 11], 11: [15, 7, 4, 3],
	12: [5, 10, 3, 11], 13: [7, 4, 3, 11], 14: [1, 3, 0, 4], 15: [7, 7, 3, 4],
	16: [8, 5, 6, 11], 17: [9, 10, 2, 15], 18: [5, 6, 11, 3], 19: [5, 10, 6, 11],
	20: [1, 3, 4, 0], 21: [6, 11, 5, 3], 22: [8, 5, 6, 11], 23: [13, 3, 0, 10],
	24: [1, 3, 4, 0], 25: [12, 6, 11, 3], 26: [7, 7, 3, 4], 27: [4, 7, 11, 3],
	28: [15, 3, 9, 11],
}


## 128x1 查表：索引 = lf + mat*32，值 = (t0,t1,t2,t3) 各存 index*17
func _kind_table() -> ImageTexture:
	var buf := PackedByteArray()
	buf.resize(128 * 4)
	for p in 128:
		var lf := p % 32
		var mat := (p - lf) / 32
		var tl: Array = LF_TILES.get(lf, [0, 2, 1, 3])
		var t0: int = tl[0]
		var t1: int = tl[1]
		var t2: int = tl[2]
		var t3: int = tl[3]
		if mat == 1:      # 砂质：更偏沙/砾
			t0 = 7
			t1 = 4
		elif mat == 2:    # 岩质：更偏碎石/岩石
			t0 = 5
			t1 = 6
		buf[p * 4] = t0 * 17
		buf[p * 4 + 1] = t1 * 17
		buf[p * 4 + 2] = t2 * 17
		buf[p * 4 + 3] = t3 * 17
	return ImageTexture.create_from_image(
			Image.create_from_data(128, 1, false, Image.FORMAT_RGBA8, buf))


func _mat() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/terrain.gdshader")
	m.set_shader_parameter("ground_atlas", _make_atlas())
	m.set_shader_parameter("kind_tex", _kind_table())
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


## ── 草 / 灌木 / 岩石的形态与分布 ─────────────────────────────────
## 草：名字, 半宽, 高, 倾斜, 颜色 r,g,b
const GRASS_KINDS := [
	["细叶草", 0.55, 0.34, 0.05, 0.90, 1.00, 0.80],
	["宽叶草", 0.85, 0.28, 0.16, 0.84, 0.96, 0.70],
	["高草", 0.62, 0.62, 0.10, 1.00, 0.96, 0.72],
	["芦苇", 0.34, 1.10, 0.04, 0.96, 1.00, 0.76],
	["苔草", 0.46, 0.18, 0.06, 0.80, 0.90, 0.72],
	["枯草丛", 0.74, 0.50, 0.22, 1.00, 0.90, 0.58],
]

## 地貌编号 → 草形态下标（0..5）
const GRASS_BY_LF := {
	0: 0, 1: 0, 2: 4, 3: 4, 4: 0, 5: 3, 6: 5, 7: 2, 8: 0, 9: 3, 10: 4,
	11: 5, 12: 1, 13: 5, 14: 2, 15: 5, 16: 4, 17: 3, 18: 4, 19: 1, 20: 2,
	21: 4, 22: 4, 23: 1, 24: 2, 25: 1, 26: 5, 27: 5, 28: 5,
}

## 地貌编号 → 灌木形态（0 矮丛 / 1 球丛 / 2 带刺灌丛）
const SHRUB_BY_LF := {
	0: 1, 1: 1, 2: 0, 3: 0, 4: 1, 5: 0, 6: 2, 7: 2, 8: 1, 9: 1, 10: 0,
	11: 0, 12: 1, 13: 2, 14: 2, 15: 2, 16: 0, 17: 1, 18: 0, 19: 1, 20: 2,
	21: 0, 22: 0, 23: 1, 24: 2, 25: 1, 26: 2, 27: 2, 28: 2,
}

## 地貌编号 → 岩石形态（0 漂砾 / 1 棱角碎石 / 2 碎石堆）
const ROCK_BY_LF := {
	0: 0, 1: 1, 2: 1, 3: 1, 4: 0, 5: 0, 6: 2, 7: 1, 8: 0, 9: 0, 10: 2,
	11: 0, 12: 1, 13: 1, 14: 1, 15: 2, 16: 1, 17: 0, 18: 1, 19: 1, 20: 1,
	21: 2, 22: 1, 23: 0, 24: 1, 25: 1, 26: 2, 27: 2, 28: 2,
}


## 多形态撒点：每个候选点按地貌选 spec，每个 spec 一个 MultiMesh
func _scatter_multi(specs: Array, lf_map: Dictionary, target: int, radius: float,
		seed_i: int, smin: float, smax: float, key: String,
		mat: Material = null) -> Node3D:
	var root := Node3D.new()
	var acc: Array = []
	for i in specs.size():
		acc.append({"trs": [], "cols": []})
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	var placed := 0
	var guard := 0
	var ft := Time.get_ticks_msec()
	while placed < target and guard < target * 6:
		guard += 1
		if Time.get_ticks_msec() - ft >= VEG_FRAME_MS:
			await get_tree().process_frame
			ft = Time.get_ticks_msec()
		var ang := rng.randf() * TAU
		var rad := sqrt(rng.randf()) * radius
		var x := cos(ang) * rad
		var z := sin(ang) * rad
		var ll := lonlat_of(x, z)
		if TG.city_blend(ll.x, ll.y).x > 0.3:
			continue
		var kind := TG.kind_baked(ll.x, ll.y)
		var prof: Dictionary = TG.BiomeLib.profile_for(kind)
		var dens: float = float(prof.get(key, 0.0))
		dens *= clampf(1.0 - (rad / radius) * 0.75, 0.2, 1.0)
		var mask := TG._vnoise(ll.x * 6.5 + 11.0, ll.y * 6.5 - 7.0, 5150)
		dens *= 0.25 + 1.5 * mask * mask
		if dens <= 0.001 or rng.randf() > dens:
			continue
		var si: int = clampi(int(lf_map.get(kind, 0)), 0, acc.size() - 1)
		var b: Dictionary = acc[si]
		if (b["trs"] as Array).size() >= BUCKET_CAP:
			continue
		var h := TG.height_xyz(x, z, center_lon, center_lat, spacing_at(rad))
		var s2 := rng.randf_range(smin, smax)
		var tr := Transform3D()
		tr = tr.scaled(Vector3(s2, s2 * rng.randf_range(0.85, 1.25), s2))
		tr = tr.rotated(Vector3.UP, rng.randf() * TAU)
		tr.origin = Vector3(x, h, z)
		(b["trs"] as Array).append(tr)
		var tc: Color = specs[si]["tint"]
		var k2 := rng.randf_range(0.85, 1.15)
		(b["cols"] as Array).append(Color(tc.r * k2, tc.g * k2, tc.b * k2))
		placed += 1
	for i in specs.size():
		var b: Dictionary = acc[i]
		var trs: Array = b["trs"]
		if trs.is_empty():
			continue
		var node := MultiMeshInstance3D.new()
		node.multimesh = _mm_fill(specs[i]["mesh"], trs, b["cols"])
		if mat == null:
			var m := StandardMaterial3D.new()
			m.vertex_color_use_as_albedo = true
			m.roughness = 0.95
			node.material_override = m
		else:
			node.material_override = mat
		root.add_child(node)
	return root


## 十字交叉面片（底边在原点），半宽/高/倾斜可调
## 草丛：3 片交叉面片 + 随机偏移，一丛而不是一根
func _make_grass_card(w: float = 0.55, h: float = 0.58, tilt: float = 0.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(w * 1000.0 + h * 137.0 + tilt * 31.0)
	for p in 3:
		var a := float(p) * PI / 3.0 + rng.randf() * 0.5
		var ww := w * (0.75 + rng.randf() * 0.5)
		var hh := h * (0.80 + rng.randf() * 0.4)
		var dx := cos(a) * ww
		var dz := sin(a) * ww
		var ox := sin(a) * ww * tilt + (rng.randf() - 0.5) * 0.12
		var oz := -cos(a) * ww * tilt + (rng.randf() - 0.5) * 0.12
		var bx := (rng.randf() - 0.5) * 0.10
		var bz := (rng.randf() - 0.5) * 0.10
		st.set_uv(Vector2(0, 1))
		st.add_vertex(Vector3(-dx + bx, 0, -dz + bz))
		st.set_uv(Vector2(1, 1))
		st.add_vertex(Vector3(dx + bx, 0, dz + bz))
		st.set_uv(Vector2(1, 0))
		st.add_vertex(Vector3(dx + ox, hh, dz + oz))
		st.set_uv(Vector2(0, 1))
		st.add_vertex(Vector3(-dx + bx, 0, -dz + bz))
		st.set_uv(Vector2(1, 0))
		st.add_vertex(Vector3(dx + ox, hh, dz + oz))
		st.set_uv(Vector2(0, 0))
		st.add_vertex(Vector3(-dx + ox, hh, -dz + oz))
	st.generate_normals()
	return st.commit()


## 撒点分帧预算（毫秒）：每撒这么多就交还一帧，加载条才不卡
const VEG_FRAME_MS := 16


## 粗网格双线性取高度（配合 _scatter_multi 里的 hgrid）
func _grid_h(g: PackedFloat32Array, n: int, fx: float, fz: float) -> float:
	fx = clampf(fx, 0.0, float(n) - 0.001)
	fz = clampf(fz, 0.0, float(n) - 0.001)
	var x0 := int(fx)
	var z0 := int(fz)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var s := n + 1
	var h00 := g[z0 * s + x0]
	var h10 := g[z0 * s + x0 + 1]
	var h01 := g[(z0 + 1) * s + x0]
	var h11 := g[(z0 + 1) * s + x0 + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


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
	# 小半径撒点（草）：先把这片地的高度按粗网格采一遍，之后双线性插值。
	# height_xyz 是 145 µs/点，草有 1.6 万个，光算高度就 2.3 秒；插值后约 3 µs/点，
	# 误差 0.3 m 以内（草 0.5 m 高，看不出来）。
	var hgrid := PackedFloat32Array()
	var hn := 0
	var hstep := 1.0
	if radius <= 300.0:
		hn = 48
		hstep = radius * 2.0 / float(hn)
		hgrid.resize((hn + 1) * (hn + 1))
		var sp0 := spacing_at(radius)
		for gy in hn + 1:
			for gx in hn + 1:
				var xx := -radius + float(gx) * hstep
				var zz := -radius + float(gy) * hstep
				hgrid[gy * (hn + 1) + gx] = TG.height_xyz(xx, zz, center_lon, center_lat, sp0)
	var ft := Time.get_ticks_msec()
	while placed < target and guard < target * 6:
		guard += 1
		if Time.get_ticks_msec() - ft >= VEG_FRAME_MS:
			await get_tree().process_frame
			ft = Time.get_ticks_msec()   # 恢复后再计时，否则帧等待会被算进预算
		var ang := rng.randf() * TAU
		var rad := sqrt(rng.randf()) * radius
		var x := cos(ang) * rad
		var z := sin(ang) * rad
		var ll := lonlat_of(x, z)
		if TG.city_blend(ll.x, ll.y).x > 0.3:
			continue
		# 查预烘焙编号图（0.5 µs/次）就够判密度组，不必再算一遍完整分类
		var kind := TG.kind_baked(ll.x, ll.y)
		var prof: Dictionary = TG.BiomeLib.profile_for(kind)
		var dens: float = float(prof.get(key, 0.0))
		# 距离衰减：近处密、远处疏，最外圈基本没有（杂物 LOD）
		dens *= clampf(1.0 - (rad / radius) * 0.75, 0.2, 1.0)
		# 密度遮罩：低频噪声形成成片的疏密区
		var mask := TG._vnoise(ll.x * 6.5 + 11.0, ll.y * 6.5 - 7.0, 5150)
		dens *= 0.25 + 1.5 * mask * mask
		if dens <= 0.001 or rng.randf() > dens:
			continue
		var h := 0.0
		if hn > 0:
			h = _grid_h(hgrid, hn, (x + radius) / hstep, (z + radius) / hstep)
		else:
			h = TG.height_xyz(x, z, center_lon, center_lat, spacing_at(rad))
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


## 灌木三种：0 松软矮丛 / 1 紧密球丛 / 2 带刺灌丛
func _make_shrub(kind: int = 0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var offs: Array
	var sizes: Array
	match kind:
		1:
			offs = [Vector3(0, 0.45, 0), Vector3(0.28, 0.38, 0.16)]
			sizes = [0.55, 0.42]
		2:
			offs = [Vector3(0, 0.50, 0), Vector3(0.34, 0.36, 0.2), Vector3(-0.30, 0.40, -0.24)]
			sizes = [0.34, 0.26, 0.22]
		_:
			offs = [Vector3(0, 0.55, 0), Vector3(0.55, 0.40, 0.2), Vector3(-0.45, 0.45, -0.3)]
			sizes = [0.62, 0.46, 0.40]
	for i in offs.size():
		var s := SphereMesh.new()
		s.radius = float(sizes[i])
		s.height = float(sizes[i]) * (1.5 if kind != 2 else 1.9)
		s.radial_segments = 7 if kind != 2 else 5
		s.rings = 3
		st.append_from(s, 0, Transform3D(Basis(Vector3.UP, float(i) * 1.1), offs[i]))
	st.generate_normals()
	return st.commit()


## 岩石三种：0 圆漂砾 / 1 棱角碎石 / 2 碎石堆
func _make_rock(kind: int = 0) -> ArrayMesh:
	var st := SurfaceTool.new()
	if kind == 2:
		for i in 3:
			var s2 := SphereMesh.new()
			s2.radius = 0.34 + 0.12 * float(i)
			s2.height = s2.radius * 1.1
			s2.radial_segments = 5
			s2.rings = 3
			var off := Vector3(float(i) * 0.42 - 0.42, 0.12 + 0.05 * float(i), float(i % 2) * 0.3)
			st.append_from(s2, 0, Transform3D(Basis(), off))
		st.generate_normals()
		return st.commit()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 1.25 if kind == 0 else 0.95
	sm.radial_segments = 7 if kind == 0 else 5
	sm.rings = 4
	var arr := sm.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	for i in verts.size():
		var v := verts[i]
		if kind == 0:
			var d := 0.62 + 0.55 * absf(TG._vnoise(v.x * 2.1 + 7.0, v.z * 2.1 - 3.0, 91))
			verts[i] = v.normalized() * d
		else:
			# 棱角：把球面推到最近的轴向平面上，做出块状
			var nn := v.normalized()
			var ax := Vector3(roundf(nn.x * 1.6) * 0.62, roundf(nn.y * 1.6) * 0.55,
					roundf(nn.z * 1.6) * 0.62)
			verts[i] = (nn * 0.45 + ax.normalized() * 0.55).normalized() * 0.9
	var st2 := SurfaceTool.new()
	st2.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in idx.size():
		st2.add_vertex(verts[idx[i]])
	st2.generate_normals()
	return st2.commit()


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
	# 先花 9 次采样探一下这片地方有没有这种地貌：没有就直接返回，
	# 省掉上千次注定失败的 landform_kind（以前 6 组专属杂物全空还要各跑 1750 次）
	var probe_hit := false
	for k in 9:
		var aa := TAU * float(k) / 8.0
		var rr := radius * (0.0 if k == 0 else 0.65)
		var l2 := lonlat_of(cos(aa) * rr, sin(aa) * rr)
		if TG.kind_baked(l2.x, l2.y) == match_lf:
			probe_hit = true
			break
	if not probe_hit:
		mm.instance_count = 0
		var empty := MultiMeshInstance3D.new()
		empty.multimesh = mm
		var em := StandardMaterial3D.new()
		em.vertex_color_use_as_albedo = true
		empty.material_override = em
		return empty
	var ft := Time.get_ticks_msec()
	while placed < target and guard < target * 5:
		guard += 1
		if Time.get_ticks_msec() - ft >= VEG_FRAME_MS:
			await get_tree().process_frame
			ft = Time.get_ticks_msec()   # 恢复后再计时，否则帧等待会被算进预算
		var ang := rng.randf() * TAU
		var rad := sqrt(rng.randf()) * radius
		var x := cos(ang) * rad
		var z := sin(ang) * rad
		var ll := lonlat_of(x, z)
		if TG.city_blend(ll.x, ll.y).x > 0.3:
			continue
		if TG.kind_baked(ll.x, ll.y) != match_lf:
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


func _build_props(progress: Callable = Callable()) -> void:
	if _veg == null:
		return
	# 草：6 种形态，按地貌选；芦苇只长在河谷/湿地/三角洲
	var gsh: Shader = load("res://shaders/grass.gdshader")
	var gmat := ShaderMaterial.new()
	if gsh != null:
		gmat.shader = gsh
		gmat.set_shader_parameter("albedo_tex", _make_grass_tex())
		gmat.set_shader_parameter("tint", Color(1.0, 1.0, 1.0))
		gmat.set_shader_parameter("wind_strength", 1.0)
	var grass_specs: Array = []
	for g in GRASS_KINDS:
		grass_specs.append({
			"mesh": _make_grass_card(float(g[1]), float(g[2]), float(g[3])),
			"tint": Color(g[4], g[5], g[6]),
		})
	_veg.add_child(await _scatter_multi(grass_specs, GRASS_BY_LF, 45000, 130.0, 7001,
			0.85, 1.35, "grass", gmat))
	if progress.is_valid():
		progress.call(0.95)

	# 灌木：3 种（松软矮丛 / 紧密球丛 / 带刺灌丛）
	var shrub_specs: Array = [
		{"mesh": _make_shrub(0), "tint": Color(0.22, 0.32, 0.15)},
		{"mesh": _make_shrub(1), "tint": Color(0.26, 0.34, 0.18)},
		{"mesh": _make_shrub(2), "tint": Color(0.30, 0.31, 0.18)},
	]
	_veg.add_child(await _scatter_multi(shrub_specs, SHRUB_BY_LF, 2600, 600.0, 7002,
			0.7, 1.6, "shrub"))
	# 岩石：3 种（圆漂砾 / 棱角碎石 / 碎石堆）
	var rock_specs: Array = [
		{"mesh": _make_rock(0), "tint": Color(0.42, 0.41, 0.38)},
		{"mesh": _make_rock(1), "tint": Color(0.46, 0.44, 0.40)},
		{"mesh": _make_rock(2), "tint": Color(0.38, 0.37, 0.35)},
	]
	_veg.add_child(await _scatter_multi(rock_specs, ROCK_BY_LF, 1400, 1200.0, 7003,
			0.35, 1.1, "rock"))
	if progress.is_valid():
		progress.call(0.97)

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
		_veg.add_child(await _scatter_special(mesh, 350, rad, 7100 + match_lf,
				float(sp[4]), float(sp[5]), col, int(sp[6]), match_lf))
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


## 叶冠：一圈随机朝向的叶卡，装在椭球里（冠幅/冠高/冠心可调）
func _make_leaf_canopy(count: int, cr: float, ch: float, cy: float,
		s0: float, s1: float, seed_i: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	for i in count:
		var a := rng.randf() * TAU
		var rr := sqrt(rng.randf()) * cr
		var y := cy + (rng.randf() - 0.5) * ch
		var center := Vector3(cos(a) * rr, y, sin(a) * rr)
		# 每片叶簇一点色差，避免一片死绿
		var k := 0.90 + rng.randf() * 0.22
		st.set_color(Color(k, k * 1.02, k * 0.92))
		_add_leaf_card(st, center, s0 + rng.randf() * (s1 - s0),
				rng.randf() * TAU, (rng.randf() - 0.5) * 1.2)
	st.generate_normals()
	return st.commit()


## ── 树种表：20 种生长型，覆盖全球主要生物群区 ──────────────────────────
## 每项：[名字, 形态, 干高, 干半径, 冠半径, 冠高, 冠心高, 层数, 叶卡数, 颜色]
## 形态：cone 锥层 / column 柱状 / solid 实心冠 / cards 叶卡冠 / palm 羽状 / bamboo 竹丛
## 只是"形状参数"：真正决定像哪儿的，是下面的 tree_mix() 群落规则。
static var _kinds: Array = []


static func tree_kinds() -> Array:
	if not _kinds.is_empty():
		return _kinds
	_kinds = [
		["云杉", "cone", 3.0, 0.14, 1.6, 1.9, 1.2, 6, 0, Color(0.17, 0.26, 0.21)],
		["冷杉", "cone", 2.4, 0.15, 1.9, 2.3, 1.0, 5, 0, Color(0.19, 0.29, 0.23)],
		["松", "cone", 4.4, 0.17, 2.1, 1.9, 4.2, 2, 0, Color(0.24, 0.32, 0.22)],
		["落叶松", "cone", 3.6, 0.13, 1.3, 1.7, 1.4, 5, 0, Color(0.35, 0.37, 0.23)],
		["白桦", "cards", 3.2, 0.10, 1.1, 1.1, 3.4, 0, 24, Color(0.44, 0.50, 0.32)],
		["橡", "cards", 2.6, 0.27, 2.7, 1.5, 3.4, 0, 38, Color(0.26, 0.34, 0.20)],
		["榆", "cards", 3.6, 0.18, 2.0, 1.4, 3.8, 0, 30, Color(0.32, 0.38, 0.24)],
		["柳", "cards", 1.8, 0.21, 2.3, 0.9, 2.2, 0, 32, Color(0.40, 0.46, 0.28)],
		["杨", "cards", 4.2, 0.14, 1.0, 2.1, 4.4, 0, 20, Color(0.36, 0.42, 0.26)],
		["樟", "cards", 3.0, 0.23, 2.5, 1.7, 3.6, 0, 42, Color(0.20, 0.32, 0.20)],
		["榕", "cards", 2.4, 0.33, 3.5, 1.1, 3.0, 0, 48, Color(0.18, 0.30, 0.18)],
		["竹", "bamboo", 5.0, 0.05, 0.8, 1.1, 4.6, 0, 10, Color(0.36, 0.46, 0.24)],
		["棕榈", "palm", 5.4, 0.15, 1.7, 0.5, 5.4, 0, 0, Color(0.30, 0.40, 0.22)],
		["金合欢", "cards", 3.2, 0.15, 3.0, 0.7, 4.4, 0, 26, Color(0.34, 0.36, 0.24)],
		["橄榄", "cards", 2.0, 0.19, 1.7, 1.1, 2.6, 0, 24, Color(0.36, 0.40, 0.32)],
		["柏", "column", 1.8, 0.17, 0.75, 4.4, 2.2, 1, 0, Color(0.18, 0.26, 0.20)],
		["柽柳", "cards", 1.6, 0.13, 1.5, 0.9, 2.0, 0, 16, Color(0.42, 0.42, 0.26)],
		["猴面包", "solid", 2.0, 0.85, 2.5, 1.3, 3.2, 0, 0, Color(0.36, 0.34, 0.24)],
		["高山矮松", "cone", 1.0, 0.11, 1.5, 0.9, 0.9, 2, 0, Color(0.20, 0.26, 0.20)],
		["苔原矮桦", "solid", 0.5, 0.09, 0.7, 0.45, 0.4, 0, 0, Color(0.38, 0.40, 0.30)],
	]
	return _kinds


## ── 群落规则：一个地区的树种组成（带优势度），而不是"一个温度带一种树" ──
## 返回 [[树种下标, 权重], ...]；权重是相对值，抽签用。
static func tree_mix(band: Vector2i, h: float, lf: int) -> Array:
	var t: int = band.x
	var m: int = band.y
	var out: Array = [[2, 1]]
	if t <= 1:
		out = [[0, 5], [3, 3], [4, 2]] if m >= 2 else [[0, 7], [3, 3]]
	elif t == 2:
		out = [[0, 3], [1, 2], [2, 2], [4, 2], [3, 1]]
	elif t == 3:
		if m >= 4:
			out = [[5, 4], [6, 3], [8, 2], [2, 1]]
		elif m == 3:
			out = [[5, 3], [6, 2], [2, 2], [4, 2], [8, 1]]
		elif m == 2:
			out = [[2, 4], [6, 2], [7, 2], [4, 2]]
		else:
			out = [[16, 4], [8, 3], [2, 3]]
	elif t == 4:
		if m >= 4:
			out = [[9, 4], [5, 2], [11, 2], [6, 2]]
		elif m == 3:
			out = [[9, 3], [5, 3], [11, 1], [2, 3]]
		elif m == 2:
			out = [[2, 3], [14, 2], [15, 2], [16, 2]]
		else:
			out = [[16, 5], [14, 3], [15, 2]]
	elif t == 5:
		if m >= 4:
			out = [[9, 3], [10, 2], [11, 3], [12, 1]]
		elif m == 3:
			out = [[9, 3], [11, 2], [2, 2], [10, 1]]
		elif m == 2:
			out = [[14, 3], [15, 3], [2, 2], [16, 1]]
		else:
			out = [[16, 4], [14, 3], [12, 2]]
	else:
		if m >= 4:
			out = [[10, 3], [12, 3], [11, 2], [9, 2]]
		elif m == 3:
			out = [[13, 3], [12, 3], [10, 2], [17, 1]]
		elif m == 2:
			out = [[13, 4], [17, 3], [12, 2]]
		else:
			out = [[12, 4], [13, 3], [16, 1]]
	# 海拔带：越高越矮、越针叶
	if h > 3600.0:
		out = [[19, 6], [18, 3]]
	elif h > 2600.0 and t <= 4:
		out = [[18, 4], [0, 3], [2, 2], [4, 1]]
	elif h > 1700.0 and t <= 3:
		out = [[0, 4], [2, 3], [4, 2], [18, 1]]
	# 河谷 / 湿地 / 沙地：地貌级的" riparian "覆盖
	if lf == 5:
		out = [[7, 5], [8, 3], [6, 1]]
	elif lf == 9 or lf == 17:
		out = [[7, 5], [8, 2], [16, 1]]
	elif lf == 6 or lf == 26 or lf == 15:
		out = [[16, 5], [8, 2], [13, 1]]
	return out


## 树干 + 冠（叶卡冠只出枝干，叶子由 _make_tree_leaf 单独出）
func _make_tree_parts(idx: int, variant: int) -> Dictionary:
	var k: Array = tree_kinds()[idx]
	var form: String = k[1]
	var rng := RandomNumberGenerator.new()
	rng.seed = 1000 + idx * 17 + variant * 7919
	var vj := 1.0 + float(variant) * 0.16 + (rng.randf() - 0.5) * 0.10
	var th: float = float(k[2]) * vj
	var tr: float = float(k[3])
	var cr: float = float(k[4]) * (0.94 + float(variant) * 0.12)
	var ch: float = float(k[5]) * vj
	var cy: float = float(k[6]) * vj
	var layers: int = int(k[7])
	# 树干（树皮）与树冠（针叶绿）分开出，才能用不同材质
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cr_st := SurfaceTool.new()
	cr_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var has_crown := false
	if form != "bamboo":
		var trunk := CylinderMesh.new()
		trunk.top_radius = tr * 0.55
		trunk.bottom_radius = tr
		trunk.height = th
		trunk.radial_segments = 6
		st.append_from(trunk, 0, Transform3D(Basis(), Vector3(0, th * 0.5, 0)))
	match form:
		"cone":
			has_crown = true
			for i in layers:
				var c := CylinderMesh.new()
				c.top_radius = 0.0
				c.bottom_radius = cr * (1.0 - 0.13 * float(i))
				c.height = ch * (1.0 - 0.10 * float(i))
				c.radial_segments = 7
				cr_st.append_from(c, 0, Transform3D(Basis(),
						Vector3(0, cy + float(i) * ch * 0.58, 0)))
		"column":
			has_crown = true
			var c2 := CylinderMesh.new()
			c2.top_radius = 0.0
			c2.bottom_radius = cr
			c2.height = ch
			c2.radial_segments = 8
			cr_st.append_from(c2, 0, Transform3D(Basis(), Vector3(0, cy + ch * 0.5, 0)))
		"solid":
			has_crown = true
			var s := SphereMesh.new()
			s.radius = cr
			s.height = ch * 2.0
			s.radial_segments = 10
			s.rings = 5
			cr_st.append_from(s, 0, Transform3D(Basis(), Vector3(0, cy + ch, 0)))
		"cards":
			for i in 3:
				var br := CylinderMesh.new()
				br.top_radius = 0.04
				br.bottom_radius = tr * 0.5
				br.height = th * 0.8
				br.radial_segments = 4
				var ang := float(i) * TAU / 3.0 + rng.randf() * 0.5
				var b := Basis(Vector3.UP, ang) * Basis(Vector3.RIGHT, 0.55)
				st.append_from(br, 0, Transform3D(b,
						Vector3(cos(ang) * tr, th * 0.95, sin(ang) * tr)))
		"palm":
			has_crown = true
			for i in 7:
				var frond := BoxMesh.new()
				frond.size = Vector3(cr * 1.9, 0.06, 0.42)
				var ang2 := float(i) * TAU / 7.0
				var b2 := Basis(Vector3.UP, ang2) * Basis(Vector3.FORWARD, -0.20)
				cr_st.append_from(frond, 0, Transform3D(b2,
						Vector3(cos(ang2) * cr * 0.85, cy, sin(ang2) * cr * 0.85)))
		"bamboo":
			has_crown = true
			for i in 4:
				var culm := CylinderMesh.new()
				culm.top_radius = tr * 0.6
				culm.bottom_radius = tr
				culm.height = th * (0.85 + rng.randf() * 0.3)
				culm.radial_segments = 4
				var off := Vector3((rng.randf() - 0.5) * 0.8, 0, (rng.randf() - 0.5) * 0.8)
				var tilt := Basis(Vector3.RIGHT, (rng.randf() - 0.5) * 0.12)
				cr_st.append_from(culm, 0, Transform3D(tilt,
						off + Vector3(0, culm.height * 0.5, 0)))
	st.generate_normals()
	cr_st.generate_normals()
	return {"trunk": st.commit(), "crown": cr_st.commit() if has_crown else null}


func _make_tree_leaf(idx: int, variant: int) -> ArrayMesh:
	var k: Array = tree_kinds()[idx]
	if int(k[8]) <= 0:
		return null
	return _make_leaf_canopy(int(k[8]), float(k[4]), float(k[5]), float(k[6]),
			0.9 + float(int(k[4]) > 2) * 0.5, 1.9 + float(int(k[4]) > 2) * 0.6,
			3000 + idx * 31 + variant * 977)


## 抽签：按权重从 mix 里挑一个树种
func _pick_weighted(mix: Array, rng: RandomNumberGenerator) -> int:
	var tot := 0.0
	for e in mix:
		tot += float(e[1])
	if tot <= 0.0:
		return 2
	var r := rng.randf() * tot
	for e in mix:
		r -= float(e[1])
		if r <= 0.0:
			return int(e[0])
	return int(mix[mix.size() - 1][0])


## 实例颜色：树种本色 × 当地基色 × 随机亮度，保持区域色彩统一
func _tree_color(ki: int, biome: int, rng: RandomNumberGenerator) -> Color:
	var t: Color = tree_kinds()[ki][9]
	var bc := TG.biome_color(biome)
	var c := t.lerp(Color(bc.r * 0.85, bc.g * 0.90, bc.b * 0.70), 0.22)
	var k := 0.88 + rng.randf() * 0.24
	return Color(c.r * k, c.g * k, c.b * k)


const BUCKET_CAP := 4000


## 注意：MultiMesh 的 instance_count 一旦重新赋值，缓冲区会被清空（4.7 实测），
## 所以必须先知道实例数、再一次性填，不能"先大后截断"。
func _mm_fill(mesh: Mesh, trs: Array, cols: Array) -> MultiMesh:
	var n := trs.size()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = n
	for i in n:
		mm.set_instance_transform(i, trs[i])
		mm.set_instance_color(i, cols[i])
	return mm


func _build_vegetation(progress: Callable = Callable()) -> void:
	if _veg != null:
		_veg.queue_free()
		_veg = null

	if TG.city_blend(center_lon, center_lat).x > 0.95:
		print("[植被] 城区内，跳过")
		return

	var assets := _load_tree_assets()
	var buckets := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = 20290
	var radius := 2600.0
	var count := 11000
	var placed := 0
	var guard := 0
	var ft := Time.get_ticks_msec()
	while placed < count and guard < 42000:
		guard += 1
		if Time.get_ticks_msec() - ft >= VEG_FRAME_MS:
			if progress.is_valid():
				progress.call(0.88 + 0.07 * float(placed) / float(count))
			await get_tree().process_frame
			ft = Time.get_ticks_msec()   # 恢复后再计时，否则帧等待会被算进预算
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
		# 按距离稀疏：近处密、远处疏（树木 LOD）
		var lod := clampf(1.0 - rad / radius * 0.55, 0.45, 1.0)
		if rng.randf() > lod:
			continue
		# 群落：温度带 × 湿度带 × 海拔 × 地貌 → 带优势度的树种组成
		var band := TG._bands(biome)
		var lf := TG.kind_baked(ll.x, ll.y)
		var ki := _pick_weighted(tree_mix(band, h_rough, lf), rng)
		var v := rng.randi() % 2
		var key := "%d_%d" % [ki, v]
		var b: Dictionary = buckets.get(key, {})
		if b.is_empty():
			b = {"ki": ki, "v": v, "trs": [], "cols": []}
			buckets[key] = b
		if (b["trs"] as Array).size() >= BUCKET_CAP:
			continue
		var h := TG.height_xyz(x, z, center_lon, center_lat, spacing_at(rad))
		var sc := (0.80 + rng.randf() * 0.55) * (0.72 + 0.55 * density)
		if not assets.is_empty():
			var am: Mesh = assets[ki % assets.size()]
			sc *= 11.0 / maxf(am.get_aabb().size.y, 0.5)
		var tr := Transform3D()
		tr = tr.scaled(Vector3(sc, sc * (0.9 + rng.randf() * 0.45), sc))
		tr = tr.rotated(Vector3.UP, rng.randf() * TAU)
		tr.origin = Vector3(x, h - 0.2, z)
		(b["trs"] as Array).append(tr)
		(b["cols"] as Array).append(_tree_color(ki, biome, rng))
		placed += 1

	_veg = Node3D.new()
	var tsh: Shader = load("res://shaders/tree.gdshader")
	var mat_leaf := ShaderMaterial.new()
	var mat_plain := ShaderMaterial.new()
	var mat_crown := ShaderMaterial.new()
	if tsh != null:
		mat_leaf.shader = tsh
		mat_leaf.set_shader_parameter("wind_strength", 1.0)
		mat_leaf.set_shader_parameter("use_tex", true)
		mat_leaf.set_shader_parameter("albedo_tex", _make_tree_tex())
		mat_leaf.set_shader_parameter("mode", 1)
		mat_plain.shader = tsh
		mat_plain.set_shader_parameter("wind_strength", 1.0)
		mat_plain.set_shader_parameter("use_tex", true)
		mat_plain.set_shader_parameter("albedo_tex", _make_tree_tex())
		mat_plain.set_shader_parameter("mode", 0)
		mat_crown.shader = tsh
		mat_crown.set_shader_parameter("wind_strength", 1.0)
		mat_crown.set_shader_parameter("use_tex", true)
		mat_crown.set_shader_parameter("albedo_tex", _make_tree_tex())
		mat_crown.set_shader_parameter("mode", 2)
	var names := ""
	for key in buckets:
		var b: Dictionary = buckets[key]
		var trs: Array = b["trs"]
		if trs.is_empty():
			continue
		var ki: int = int(b["ki"])
		var v: int = int(b["v"])
		var white: Array = []
		for i in trs.size():
			white.append(Color(1, 1, 1))
		if not assets.is_empty():
			var am: Mesh = assets[ki % assets.size()]
			var an := MultiMeshInstance3D.new()
			an.multimesh = _mm_fill(am, trs, b["cols"])
			an.material_override = mat_plain
			_veg.add_child(an)
		else:
			var parts := _make_tree_parts(ki, v)
			var tnode := MultiMeshInstance3D.new()
			tnode.multimesh = _mm_fill(parts["trunk"], trs, b["cols"])
			tnode.material_override = mat_plain
			_veg.add_child(tnode)
			if parts["crown"] != null:
				var cnode := MultiMeshInstance3D.new()
				cnode.multimesh = _mm_fill(parts["crown"], trs, b["cols"])
				cnode.material_override = mat_crown
				_veg.add_child(cnode)
			var lm := _make_tree_leaf(ki, v)
			if lm != null:
				var ln := MultiMeshInstance3D.new()
				ln.multimesh = _mm_fill(lm, trs, white)
				ln.material_override = mat_leaf
				_veg.add_child(ln)
		var sp_name: String = tree_kinds()[ki][0]
		if names.find(sp_name) < 0:
			names += sp_name + " "
	add_child(_veg)
	print("[植被] %d 棵 / %d 个网格，树种：%s" % [placed, buckets.size(), names])
	await _build_props(progress)
