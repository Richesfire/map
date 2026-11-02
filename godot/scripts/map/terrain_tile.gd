class_name TerrainTile
extends Node3D

## ==============================================================
## 一个地块的渲染层（球面版）
##
## 几何怎么来的：
##   整个区域共享一个**切平面坐标系**（东/北/天），地块是切平面上的
##   1km × 1km 方格。每个顶点的做法是：
##       1. 切平面偏移 (u, v) -> 球面方向 dir = normalize(up + (east·u + north·v)/R)
##       2. 在 dir 上采样三维噪声得到高度 h
##       3. 球面位置 = dir·(R + h)，再减掉区域原点的球面位置
##       4. 投影到切平面基底，得到区域局部坐标
##
##   因为同一区域内所有地块共用同一个切平面坐标系、同一套 dir 计算，
##   相邻地块边界上的顶点**算出来是同一个值** —— 拼接零缝隙。
##   跨立方体面也一样，因为地形是三维噪声在球面上的采样。
##
## 【为什么用 double 算位置】
##   球面位置量级 6.37×10⁶ 米，而 Godot 的 Vector3 是 32 位浮点
##   （那个量级精度只剩 0.5 米）。所以位置一律用 GDScript 的 float
##   （64 位）算完再塞进 Vector3，塞进去的值只有几公里，精度足够。
##
## 【撒点为什么可复现】
##   用"格点哈希"而不是随机数序列：同一区域内重复生成结果完全一致，
##   跨地块也不会出现树突然断掉或重复种两棵。
##   注意：撒点网格是**以区域为锚**的，换一个区域中心重新生成，
##   树的相对位置会整体平移一次（地块地形本身不受影响）。
## ==============================================================

const RES_MIN := 9

var cfg: MapConfig
var gen: TerrainNoise
var ground_material: ShaderMaterial
var prop_material: StandardMaterial3D
var prop_meshes: Dictionary = {}

## 会影响到本格的选定地块（由 MapWorld 传入，默认空）
var designated: Array = []
## 区域切平面坐标系 {up, east, north}
var frame: Dictionary = {}
## 本格在切平面上的起始偏移（米）与中心偏移
var u0 := 0.0
var v0 := 0.0
var u_center := 0.0
var v_center := 0.0
var build_scatter := true
var biome_id := "plain"
var biome_color := Color.WHITE
var biome_map: BiomeMap = null      # 逐顶点取群系颜色用
var biome_parts: Dictionary = {}      # kind -> [零件编号]

## 本格的球面地址 (face, x, y)
var sphere_tile := Vector3i.ZERO
## 本格在区域网格里的位置
var grid_pos := Vector2i.ZERO

var _h := PackedFloat32Array()
var _hn := 0
var _hstep := 0.0


func setup(grid: Vector2i, s_tile: Vector3i, config: MapConfig, noise_gen: TerrainNoise,
		region_frame: Dictionary) -> void:
	grid_pos = grid
	sphere_tile = s_tile
	cfg = config
	gen = noise_gen
	frame = region_frame

	name = "Tile_%d_%d_%d" % [s_tile.x, s_tile.y, s_tile.z]
	position = Vector3(u_center, 0.0, -v_center)


func build() -> void:
	_build_terrain()
	if build_scatter:
		_build_scatter()


# ================================================================ 几何换算
## 切平面偏移 -> 球面方向
func _dir_at(u: float, v: float) -> Vector3:
	return GeoSphere.tangent_to_dir(frame, u, v)


## 区域局部坐标（x=东, y=天, z=南）。
##
## 不用"方向 × 半径再投影到基底"那种写法：方向是 32 位 Vector3，
## 乘上 6.37e6 之后误差会被放大到 0.5 米，地形会出现细微抖动。
## 这里直接解析求解：
##   球面点 = (up·R + east·u + north·v) 归一化后 × (R + h)
##   减掉区域原点 up·R，投影到 (east, up, north) 基底后得到
##     东 = u·k,  天 = R·k − R,  北 = v·k,  其中 k = (R+h)/|up·R + T|
## 全程 64 位，精度到毫米以下。
func _local_at(u: float, v: float, h: float) -> Vector3:
	var r := GeoSphere.RADIUS_M
	var l := sqrt(r * r + u * u + v * v)
	var k := (r + float(h)) / l
	return Vector3(u * k, r * k - r, -(v * k))


## 含选定地块处理的真实地表高度
func sample_height(dir: Vector3) -> float:
	var h := gen.height_at(dir)
	if designated.is_empty():
		return h
	return DesignatedTileRegistry.apply_flatten(designated, dir, h)


## 含平台的、切平面偏移处的高度
func height_at_uv(u: float, v: float) -> float:
	return sample_height(_dir_at(u, v))


# ================================================================ 白膜 + 网格
## ================================================================ 分帧构建
## 一块 1km² 完整建完约 400ms（地形 170 + 撒点 226），跨块时会明显卡一帧。
## 拆成"粗版立刻上、细节分帧补"：
##   1) 粗版 33×33 网格 + 碰撞      约 12ms  —— 玩家马上有地站
##   2) 精细高度采样，每帧 2 行     约 20ms/帧
##   3) 提交精细网格 + 碰撞         约 30ms
##   4) 密度场，每帧一层            约 20ms
##   5) 撒点，每帧按行推进          约 25ms
## 这样任何一帧的峰值都压在 35ms 以内，跨块不再有可感知的停顿。

const COARSE_RES := 33
const FINE_ROWS_PER_STEP := 2
const SCATTER_ROWS_PER_STEP := 10

var _res := 0
var _sample_row := 0
var _ground: MeshInstance3D
var _collider: StaticBody3D
var _mesh_for_collision: Mesh

var _job_active := false
var _job_phase := 0
var _job_row := 0
var _job_kind := 0
var _job_collected: Array = []
var _job_kinds := ["tree", "rock", "low_veg"]
var _job_arr := PackedFloat32Array()


func _begin_grid(res: int) -> void:
	_res = res
	_hstep = cfg.tile_size_m / float(res - 1)
	_hn = res + 2
	_h.resize(_hn * _hn)
	_sample_row = 0


## 采样若干行高度，返回是否采完
func _sample_rows(rows: int) -> bool:
	var step := _hstep
	var end := mini(_sample_row + rows, _hn)
	for j in range(_sample_row, end):
		var vv := v0 - step + float(j) * step
		var row := j * _hn
		for i in _hn:
			_h[row + i] = height_at_uv(u0 - step + float(i) * step, vv)
	_sample_row = end
	return _sample_row >= _hn


func _commit_mesh() -> void:
	var res := _res
	var step := _hstep
	var count := res * res
	var verts := PackedVector3Array()
	verts.resize(count)
	var norms := PackedVector3Array()
	norms.resize(count)
	var cols := PackedColorArray()
	cols.resize(count)
	var origin := Vector3(u_center, 0.0, -v_center)
	const COL_STRIDE := 2   # 每 2 格采一次群系颜色，GPU 插值补中间
	var last_col := biome_color

	for j in res:
		for i in res:
			var k := j * res + i
			var pi := i + 1
			var pj := j + 1
			var row := pj * _hn
			var uu := u0 + float(i) * step
			var vv := v0 + float(j) * step

			verts[k] = _local_at(uu, vv, _h[row + pi]) - origin

			if biome_map != null and i % COL_STRIDE == 0 and j % COL_STRIDE == 0:
				last_col = MapWorld.BIOME_TINTS.get(
						biome_map.biome_at(GeoSphere.tangent_to_dir(frame, uu, vv)),
						biome_color)
			cols[k] = last_col

			var hl := _h[row + pi - 1]
			var hr := _h[row + pi + 1]
			var hd := _h[row - _hn + pi]
			var hu := _h[row + _hn + pi]
			norms[k] = Vector3(
					-(hr - hl) / (2.0 * step),
					1.0,
					-(hu - hd) / (2.0 * step)).normalized()

	var indices := PackedInt32Array()
	indices.resize((res - 1) * (res - 1) * 6)
	var n := 0
	for j in res - 1:
		for i in res - 1:
			var a := j * res + i
			var b := a + 1
			var c := a + res
			var d := c + 1
			# 绕序：局部坐标是 x=东、z=南（z 取了负），
			# 所以和"平坦网格"的常规写法相比要反过来，否则法线朝下、整片发黑
			indices[n] = a
			indices[n + 1] = c
			indices[n + 2] = b
			indices[n + 3] = b
			indices[n + 4] = c
			indices[n + 5] = d
			n += 6

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = indices
	arrays[Mesh.ARRAY_COLOR] = cols

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# 粗版 -> 细版：直接换掉，不叠加
	if _ground != null and is_instance_valid(_ground):
		_ground.mesh = mesh
	else:
		_ground = MeshInstance3D.new()
		_ground.name = "Ground"
		_ground.material_override = _make_tinted_material()
		add_child(_ground)
		_ground.mesh = mesh

	_mesh_for_collision = mesh


## 碰撞单独一步，**和视觉网格同精度**
func build_collision() -> void:
	if not cfg.collision:
		return
	var src := _mesh_for_collision
	if src == null:
		return
	if _collider != null and is_instance_valid(_collider):
		_collider.queue_free()

	# 碰撞必须和视觉网格同精度（stride=1）。
	# 之前为了省时间用了半精度（129->65），结果山丘的碰撞面比看到的低，
	# 骑马冲上去会直接沉进山体里 —— 宁可这一帧多花 60ms，也不能穿模。
	var step_s := 1
	var coarse := maxi(3, int(floor(float(_res - 1) / float(step_s))) + 1)
	var verts := PackedVector3Array()
	verts.resize(coarse * coarse)
	var origin := Vector3(u_center, 0.0, -v_center)
	var hstep := _hstep
	for j in coarse:
		for i in coarse:
			var pi := mini(i * step_s + 1, _hn - 2)
			var pj := mini(j * step_s + 1, _hn - 2)
			var uu := u0 + float(i) * float(step_s) * hstep
			var vv := v0 + float(j) * float(step_s) * hstep
			verts[j * coarse + i] = _local_at(uu, vv, _h[pj * _hn + pi]) - origin

	var indices := PackedInt32Array()
	indices.resize((coarse - 1) * (coarse - 1) * 6)
	var n := 0
	for j in coarse - 1:
		for i in coarse - 1:
			var a := j * coarse + i
			var b := a + 1
			var c := a + coarse
			var d := c + 1
			indices[n] = a; indices[n + 1] = c; indices[n + 2] = b
			indices[n + 3] = b; indices[n + 4] = c; indices[n + 5] = d
			n += 6

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var cm := ArrayMesh.new()
	cm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var body := StaticBody3D.new()
	body.name = "Collider"
	var col := CollisionShape3D.new()
	col.shape = cm.create_trimesh_shape()
	body.add_child(col)
	add_child(body)
	_collider = body


func _build_terrain_at(res: int) -> void:
	_begin_grid(res)
	_sample_rows(_hn)
	_commit_mesh()


func _build_terrain() -> void:
	_build_terrain_at(maxi(cfg.mesh_res, RES_MIN))
	build_collision()


## 开始分帧构建。two_stage=true 时先用粗网格立刻给一块能站的地。
func begin_job(do_scatter: bool, two_stage: bool) -> void:
	_job_active = true
	_job_phase = 0
	_job_row = 0
	_job_kind = 0
	_job_collected = []
	build_scatter = do_scatter
	if two_stage:
		_build_terrain_at(COARSE_RES)
		_begin_grid(maxi(cfg.mesh_res, RES_MIN))
	else:
		_begin_grid(maxi(cfg.mesh_res, RES_MIN))


## 推进一步，返回 true 表示全部完成
func step_job() -> bool:
	if not _job_active:
		return true
	return _step_job_inner()


func _step_job_inner() -> bool:
	match _job_phase:
		0:
			if _sample_rows(FINE_ROWS_PER_STEP):
				_job_phase = 1
		1:
			# 视觉网格和碰撞**同一步提交**：两者来自同一份高度数据，
			# 分开做只会让"看得见但站不住"的窗口变长。
			_commit_mesh()
			build_collision()
			_job_phase = 2 if build_scatter else 4
		2:
			# 密度场：一层一层来，每帧只填 8 行
			var kind2: String = _job_kinds[_job_kind]
			var n := DENS_N + 1
			if _job_row == 0:
				_job_arr = PackedFloat32Array()
				_job_arr.resize(n * n)
			var j_to := mini(_job_row + 8, n)
			_fill_density_rows(kind2, _job_row, j_to, _job_arr)
			_job_row = j_to
			if _job_row >= n:
				_dens[kind2] = _job_arr
				_job_arr = PackedFloat32Array()
				_job_row = 0
				_job_kind += 1
				if _job_kind >= _job_kinds.size():
					_job_kind = 0
					_job_phase = 3
		3:
			var kind: String = _job_kinds[_job_kind]
			var step_m: float = _kind_step(kind)
			var total_rows := _collect_row_count(kind, step_m)
			var j_to := mini(_job_row + SCATTER_ROWS_PER_STEP, total_rows)
			_job_collected.append_array(_collect_rows(kind, step_m, _job_row, j_to))
			_job_row = j_to
			if _job_row >= total_rows:
				_add_layer(kind, _job_collected, kind != "low_veg")
				_job_collected = []
				_job_row = 0
				_job_kind += 1
				if _job_kind >= _job_kinds.size():
					_job_phase = 4
		4:
			_job_active = false
			return true
	return false


func _kind_step(kind: String) -> float:
	match kind:
		"tree":
			return cfg.tree_step_m
		"rock":
			return cfg.rock_step_m
		"low_veg":
			return cfg.low_veg_step_m
	return 0.0

## .glb 零件缓存：同一个编号整个进程只加载一次
static var _glb_cache: Dictionary = {}


func _glb_mesh(pid: String) -> Mesh:
	if _glb_cache.has(pid):
		return _glb_cache[pid]
	var path := "res://assets/parts/%s.glb" % pid
	var m: Mesh = null
	if ResourceLoader.exists(path):
		var ps := load(path) as PackedScene
		if ps != null:
			var inst := ps.instantiate()
			m = _find_mesh(inst)
			inst.queue_free()
	_glb_cache[pid] = m
	return m


func _find_mesh(n: Node) -> Mesh:
	if n is MeshInstance3D:
		return (n as MeshInstance3D).mesh
	for c in n.get_children():
		var m := _find_mesh(c)
		if m != null:
			return m
	return null


## 这一类零件该用哪个模型：有生物群系就给 glb，没有就退回程序化占位
func _mesh_for_kind(kind: String) -> Mesh:
	# 只要这个地形在表里出现过，就**以表为准**：
	# 表里这一类是空的（海洋没树、冰原没草），就该什么都不长，
	# 绝不能退回占位圆锥——否则传送到海上会冒出一片树林。
	if not biome_parts.is_empty():
		var ids: Array = biome_parts.get(kind, [])
		if ids.is_empty():
			return null
		var idx := absi(hash(str(grid_pos) + kind)) % ids.size()
		var m := _glb_mesh(str(ids[idx]))
		if m == null:
			return null
		return m
	return prop_meshes.get(kind)


func _build_scatter() -> void:
	_build_density_fields()
	_add_layer("tree", _collect("tree", cfg.tree_step_m), true)
	_add_layer("rock", _collect("rock", cfg.rock_step_m), true)
	_add_layer("low_veg", _collect("low_veg", cfg.low_veg_step_m), false)


## 密度场是低频的（噪声尺度在百米级），按 7m 间距逐点查是严重过采样。
## 这里先按 32x32 粗网格采样一次，之后双线性插值。
## 1km 一块：噪声调用从 6.8 万次降到 3x33x33 = 3267 次。
const DENS_N := 32
var _dens: Dictionary = {}


func _fill_density_rows(kind: String, r_from: int, r_to: int, arr: PackedFloat32Array) -> void:
	var size := cfg.tile_size_m
	var n := DENS_N + 1
	for j in range(r_from, r_to):
		var vv := v0 + float(j) / float(DENS_N) * size
		var row := j * n
		for i in n:
			var uu := u0 + float(i) / float(DENS_N) * size
			arr[row + i] = _density(kind, _dir_at(uu, vv), _slope_deg_fast(uu, vv))


func _build_density_field(kind: String) -> void:
	var n := DENS_N + 1
	var arr := PackedFloat32Array()
	arr.resize(n * n)
	_fill_density_rows(kind, 0, n, arr)
	_dens[kind] = arr


func _build_density_fields() -> void:
	for kind in ["tree", "rock", "low_veg"]:
		_build_density_field(kind)


func _density_fast(kind: String, uu: float, vv: float) -> float:
	var arr: PackedFloat32Array = _dens.get(kind, PackedFloat32Array())
	if arr.is_empty():
		return 0.0
	var size := cfg.tile_size_m
	var fx := clampf((uu - u0) / size, 0.0, 1.0) * float(DENS_N)
	var fy := clampf((vv - v0) / size, 0.0, 1.0) * float(DENS_N)
	var i0 := clampi(int(floorf(fx)), 0, DENS_N - 1)
	var j0 := clampi(int(floorf(fy)), 0, DENS_N - 1)
	var tx := fx - float(i0)
	var ty := fy - float(j0)
	var n := DENS_N + 1
	var a := arr[j0 * n + i0]
	var b := arr[j0 * n + i0 + 1]
	var c := arr[(j0 + 1) * n + i0]
	var d := arr[(j0 + 1) * n + i0 + 1]
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), ty)


func _add_layer(kind: String, xforms: Array, cast_shadow: bool) -> void:
	if xforms.is_empty():
		return
	var mesh: Mesh = _mesh_for_kind(kind)
	if mesh == null:
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Layer_" + kind
	mmi.multimesh = mm
	# 只有用程序化占位几何时才套共享材质（靠顶点色上色）。
	# 用 Blender 导出的真模型时 prop_material 应该是 null，让模型自带材质生效。
	if prop_material != null and biome_parts.get(kind, []).is_empty():
		mmi.material_override = prop_material
	if cast_shadow:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	else:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


func _row_bounds(step_m: float) -> Vector2i:
	var size := cfg.tile_size_m
	return Vector2i(int(floor(v0 / step_m)), int(ceil((v0 + size) / step_m)))


func _collect_row_count(_kind: String, step_m: float) -> int:
	var b := _row_bounds(step_m)
	return b.y - b.x


func _collect(kind: String, step_m: float) -> Array:
	return _collect_rows(kind, step_m, 0, _collect_row_count(kind, step_m))


## 只处理 [r_from, r_to) 这段行，供分帧构建用
func _collect_rows(kind: String, step_m: float, r_from: int, r_to: int) -> Array:
	var out: Array = []
	if gen == null or step_m <= 0.0:
		return out

	var size := cfg.tile_size_m
	var i0 := int(floor(u0 / step_m))
	var i1 := int(ceil((u0 + size) / step_m))
	var b := _row_bounds(step_m)
	var j0 := b.x + r_from
	var j1 := b.x + r_to

	for gj in range(j0, j1):
		for gi in range(i0, i1):
			var jx := _hash01(gi, gj, 11) - 0.5
			var jz := _hash01(gi, gj, 12) - 0.5
			var uu := (float(gi) + 0.5 + jx * 0.9) * step_m
			var vv := (float(gj) + 0.5 + jz * 0.9) * step_m
			if uu < u0 or uu >= u0 + size or vv < v0 or vv >= v0 + size:
				continue

			# 选定地块里不长东西（默认没有，就不用算方向了）
			if not designated.is_empty():
				if DesignatedTileRegistry.is_scatter_blocked(designated, _dir_at(uu, vv)):
					continue

			var d := _density_fast(kind, uu, vv)
			if d <= 0.0:
				continue
			if _hash01(gi, gj, 13) > d:
				continue
			out.append(_make_transform(kind, gi, gj, uu, vv))
	return out


func _density(kind: String, dir: Vector3, sl: float) -> float:
	match kind:
		"tree":
			return gen.tree_density(dir, sl)
		"rock":
			return gen.rock_density(dir, sl)
		"low_veg":
			return gen.low_veg_density(dir, sl)
	return 0.0


func _make_transform(kind: String, gi: int, gj: int, uu: float, vv: float) -> Transform3D:
	var h := _height_fast(uu, vv)
	# 位置走和地形顶点同一套解析式，球面曲率才不会让物件浮起来或陷进去
	var local := _local_at(uu, vv, h) - Vector3(u_center, 0.0, -v_center)
	var lx := local.x
	var ly := local.y
	var lz := local.z

	match kind:
		"tree":
			var ts := 0.72 + _hash01(gi, gj, 21) * 0.70
			var tsy := ts * (0.80 + _hash01(gi, gj, 22) * 0.65)
			var tb := Basis(Vector3.UP, _hash01(gi, gj, 23) * TAU).scaled(
					Vector3(ts, tsy, ts))
			return Transform3D(tb, Vector3(lx, ly - 0.15, lz))
		"rock":
			var rs := 0.7 + _hash01(gi, gj, 31) * 1.5
			var rot := Vector3(
					_hash01(gi, gj, 32) * TAU,
					_hash01(gi, gj, 33) * TAU,
					_hash01(gi, gj, 34) * TAU)
			var rb := Basis.from_euler(rot).scaled(Vector3(rs * 1.2, rs * 0.72, rs * 1.05))
			return Transform3D(rb, Vector3(lx, ly - 0.12, lz))
		_:
			var ls := 0.65 + _hash01(gi, gj, 41) * 0.80
			var lsy := ls * (0.70 + _hash01(gi, gj, 42) * 0.90)
			var lb := Basis(Vector3.UP, _hash01(gi, gj, 43) * TAU).scaled(
					Vector3(ls, lsy, ls))
			return Transform3D(lb, Vector3(lx, ly, lz))


# ================================================================ 辅助
## 在本地高度栅格上双线性取值，比重新算十几次噪声快得多
func _height_fast(u: float, v: float) -> float:
	var fx := (u - (u0 - _hstep)) / _hstep
	var fz := (v - (v0 - _hstep)) / _hstep
	var i0 := int(floor(fx))
	var j0 := int(floor(fz))
	if i0 < 0 or j0 < 0 or i0 >= _hn - 1 or j0 >= _hn - 1:
		return height_at_uv(u, v)

	var tx := fx - float(i0)
	var tz := fz - float(j0)
	var r0 := j0 * _hn + i0
	var r1 := r0 + _hn
	return lerpf(
			lerpf(_h[r0], _h[r0 + 1], tx),
			lerpf(_h[r1], _h[r1 + 1], tx),
			tz)


func _slope_deg_fast(u: float, v: float) -> float:
	var e := _hstep
	var hx := (_height_fast(u + e, v) - _height_fast(u - e, v)) / (2.0 * e)
	var hz := (_height_fast(u, v + e) - _height_fast(u, v - e)) / (2.0 * e)
	return rad_to_deg(atan(sqrt(hx * hx + hz * hz)))


## 格点哈希：同一区域内同一个 (gi, gj) 永远是同一个值
static func _hash01(x: int, y: int, salt: int) -> float:
	var h := (x * 374761393 + y * 668265263 + salt * 1442695041) & 0x7FFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	h = h ^ (h >> 16)
	return float(h & 0xFFFF) / 65535.0


## 每块地一份材质实例，只为了给 biome_tint 传不同的颜色。
func _make_tinted_material() -> Material:
	if ground_material is ShaderMaterial:
		var m := (ground_material as ShaderMaterial).duplicate() as ShaderMaterial
		m.set_shader_parameter("biome_tint", biome_color)
		m.set_shader_parameter("biome_tint_strength", 0.82)
		return m
	return ground_material
