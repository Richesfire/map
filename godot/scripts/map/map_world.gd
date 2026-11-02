class_name MapWorld
extends Node3D

## ==============================================================
## 地图模块的门面 —— 对外**只**通过这个类
##
## 用法：
##     var map := MapWorld.new()
##     map.setup(MapConfig.new(), 209, designated_tiles)
##     add_child(map)
##     map.build(GeoSphere.lonlat_to_dir(108.71, 34.33), 3, 3)
##
## 建完之后，任何时候都可以问它问题（参数都是**单位方向**）：
##     map.get_height_dir(dir)    地表高度（含选定地块平台），米
##     map.dir_to_tile(dir)       这个方向属于哪一格 Vector3i(面, x, y)
##     map.designated_tile_at_dir(dir)  这一格是不是你手工圈定的
##     map.render_position(dir)   直接能塞进 Vector3 的局部渲染坐标
##     map.get_height_lonlat(108.71, 34.33)   嫌算方向麻烦就直接给经纬度
##
## 距离一律用 GeoSphere.distance_m(a, b)，**不要拿格子索引差值算**。
## 完整契约见 docs/MAP_API.md
## ==============================================================

signal region_built(center_dir: Vector3, tiles_x: int, tiles_z: int)
signal designated_tile_placed(tile: DesignatedTile, local_position: Vector3)

var cfg: MapConfig
var gen: TerrainNoise
var registry: DesignatedTileRegistry
var world_seed := 209

## 本次加载区域的中心方向
var region_center_dir := Vector3.UP
## 区域切平面坐标系 {up, east, north}
var region_frame: Dictionary = {}

## 地图标注（只给小地图画点用，不影响生成）
var annotations: Array = []

var _tiles: Dictionary = {}          # Vector3i(面,x,y) -> TerrainTile
var _grid: Dictionary = {}           # Vector2i(区域网格) -> TerrainTile
var _frame_root: Node3D
var _tile_root: Node3D
var _marker_root: Node3D
var _ground_material: ShaderMaterial
var _prop_material: StandardMaterial3D
var _prop_meshes: Dictionary = {}
var _built := false
var tiles_ready := 0    # 每建成一块（含碰撞）就 +1
var biome: BiomeMap

## 地表染色（和地球仪上那套同源，只是压淡一些，免得地面过饱和）
const BIOME_TINTS := {
	"ocean": Color(0.25, 0.42, 0.62),
	"ice": Color(0.93, 0.96, 1.00),
	"tundra": Color(0.52, 0.56, 0.50),
	"alpine": Color(0.72, 0.74, 0.74),
	"mountain": Color(0.52, 0.50, 0.45),
	"hills": Color(0.52, 0.64, 0.38),
	"forest": Color(0.34, 0.52, 0.30),
	"jungle": Color(0.26, 0.50, 0.24),
	"savanna": Color(0.80, 0.75, 0.46),
	"steppe": Color(0.74, 0.70, 0.44),
	"desert": Color(0.88, 0.78, 0.55),
	"badland": Color(0.80, 0.75, 0.68),
	"marsh": Color(0.42, 0.52, 0.40),
	"plain": Color(0.55, 0.72, 0.40),
	"inland_water": Color(0.30, 0.48, 0.62),
}
var _biome_parts: Dictionary = {}
var _tiles_x := 0
var _tiles_z := 0
var _half_x := 0.0
var _half_z := 0.0
var _stream_radius := 0
var _stream_center := Vector2i(-99999, -99999)
var _building: Array = []   # 正在分帧构建的地块
var _last_pos := Vector3.ZERO
var _vel := Vector3.ZERO


# ================================================================ 装配
func setup(config: MapConfig = null, seed_value: int = 209, reg: DesignatedTileRegistry = null) -> void:
	if config == null:
		cfg = MapConfig.new()
	else:
		cfg = config
	world_seed = seed_value

	gen = TerrainNoise.new(cfg, world_seed)

	if reg == null:
		registry = DesignatedTileRegistry.new()
	else:
		registry = reg

	if not registry.is_resolved():
		registry.resolve(gen)

	_build_materials()

	# 区域根：只做朝向，不平移。
	# 如果把根节点平移到球面上（6.37e6 米），子节点的 global_transform
	# 在 float32 下会掉到 0.5 米精度。所以球面位置只参与数学计算，
	# 节点坐标永远是"切平面上的米"，量级只有几公里。
	_frame_root = Node3D.new()
	_frame_root.name = "RegionFrame"
	add_child(_frame_root)

	_tile_root = Node3D.new()
	_tile_root.name = "Tiles"
	_frame_root.add_child(_tile_root)

	_marker_root = Node3D.new()
	_marker_root.name = "DesignatedMarkers"
	_frame_root.add_child(_marker_root)


## 铺一片地块。center_dir 是区域中心的单位方向。
func build(center_dir: Vector3, tiles_x: int, tiles_z: int, do_scatter: bool = true) -> void:
	if gen == null:
		push_error("MapWorld.build(): 先调用 setup()")
		return

	region_center_dir = center_dir.normalized()
	region_frame = GeoSphere.tangent_frame(region_center_dir)
	_tiles_x = tiles_x
	_tiles_z = tiles_z
	_half_x = float(tiles_x) * 0.5
	_half_z = float(tiles_z) * 0.5

	# 区域根**不做旋转**。
	# 地形顶点本身已经算成「x=东, y=天, z=南」的局部坐标（见 TerrainTile._local_at），
	# 所以这里再套一层旋转只会让世界 Y 和当地"上"错开，
	# 导致玩家、相机、灯光全部歪掉。保持单位变换，大家就都在同一个 Y 朝上的空间里。
	_frame_root.transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)

	_clear_children(_tile_root)
	_clear_children(_marker_root)
	_tiles.clear()
	_grid.clear()

	var half_x := float(tiles_x) * 0.5
	var half_z := float(tiles_z) * 0.5
	var size := cfg.tile_size_m

	for j in tiles_z:
		for i in tiles_x:
			_spawn_tile(i, j, do_scatter)

	_place_designated()
	_built = true
	region_built.emit(region_center_dir, tiles_x, tiles_z)
# ================================================================ 流式加载
## 只保留玩家周围 (2r+1)^2 个地块，其余释放。
## 每帧调一次；没有要补的格子时几乎零开销。
# ================================================================ 远景壳
## 3x3 只有 3km，而雾的能见度有 4~5km，所以地平线上会露出"世界边缘"。
## 解法不是多铺地块（每块 400ms），而是铺一张**低精度的大网**：
##   18km x 18km，97x97 顶点（约 190m 一格），不撒点、不建碰撞。
## 高度仍然来自同一个 height_at()，所以和近处地块对得上；
## 整张网往下压 3m，让近处的高精度地块永远盖在上面，接缝看不出来。
## 只按玩家 1.2km 的移动重建一次（约 70ms）。
const FAR_EXTENT := 9000.0
const FAR_RES := 96
## 挖洞但**比地块小**：地块覆盖 ±1500m，洞挖到 1250m，
## 所以 1250~1500 这一段壳藏在瓦片底下，瓦片边缘之外立刻接上壳 —— 无缝、无台阶。
## 下压要足够大：远景壳 190m 一格，粗网在坡地上会顶穿精细地形（看起来像两层地面重叠）。
## 挖洞省不到 2% 的三角形，却会留下缺口和 z-fighting 风险，得不偿失。
const FAR_HOLE := 900.0

var _far_shell: MeshInstance3D
var _far_center := Vector3(1e9, 0.0, 0.0)


func enable_far_shell() -> void:
	if _far_shell != null:
		return
	_far_shell = MeshInstance3D.new()
	_far_shell.name = "FarShell"
	# 壳用**独立材质**并设成只渲染正面：万一人物到了壳下面，看到的是天空而不是黑面
	if _ground_material is ShaderMaterial:
		var sm := (_ground_material as ShaderMaterial).duplicate() as ShaderMaterial
		sm.render_priority = -1
		_far_shell.material_override = sm
	else:
		_far_shell.material_override = _ground_material
	_far_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_frame_root.add_child(_far_shell)


func _update_far_shell(pos: Vector3) -> void:
	if _far_shell == null:
		return
	if _far_shell.mesh != null and Vector2(pos.x - _far_center.x, pos.z - _far_center.z).length() < 1200.0:
		return
	var t0 := Time.get_ticks_msec()
	_far_center = pos

	var n := FAR_RES + 1
	var step := FAR_EXTENT * 2.0 / float(FAR_RES)
	var verts := PackedVector3Array()
	verts.resize(n * n)
	# 逐顶点群系色：shader 现在优先用顶点色，不写就会是白的
	var fcols := PackedColorArray()
	fcols.resize(n * n)
	var neutral: Color = BIOME_TINTS.get("plain", Color(0.55, 0.72, 0.40))

	for j in n:
		for i in n:
			var x := pos.x - FAR_EXTENT + float(i) * step
			var z := pos.z - FAR_EXTENT + float(j) * step
			var dir := GeoSphere.tangent_to_dir(region_frame, x, -z)
			var p := render_position(dir)

			# 曾经试过按距离渐变下沉，但壳是 190m 一格，下沉量逐点变化会形成
			# 一圈圈台阶（屏幕上就是波浪状条纹）。改回恒定下压，靠瓦片盖住。
			verts[j * n + i] = Vector3(p.x, p.y - 2.0, p.z)
			if biome != null:
				fcols[j * n + i] = BIOME_TINTS.get(biome.biome_at(dir), neutral)
			else:
				fcols[j * n + i] = neutral

	var idx := PackedInt32Array()
	var k := 0
	for j in FAR_RES:
		for i in FAR_RES:
			# 洞：精细瓦片覆盖的区域不生成壳，避免"地里有地"和多余面数
			var cx := pos.x - FAR_EXTENT + (float(i) + 0.5) * step
			var cz := pos.z - FAR_EXTENT + (float(j) + 0.5) * step
			if absf(cx - pos.x) < FAR_HOLE and absf(cz - pos.z) < FAR_HOLE:
				continue
			var a := j * n + i
			var b := a + 1
			var c := a + n
			var d := c + 1
			# 这里的 j 往 +z（南）走，和地形瓦片（v 往 -z）是镜像，
			# 所以绕序要反过来，否则整张网背面朝上、被剔除掉
			idx.append(a); idx.append(b); idx.append(c)
			idx.append(b); idx.append(d); idx.append(c)


	# 法线必须算：全朝上会让远景壳的光照和精细地块明显不同，交界处出现色差线
	var normals := PackedVector3Array()
	normals.resize(n * n)
	for j in n:
		for i in n:
			var il := maxi(i - 1, 0)
			var ir := mini(i + 1, n - 1)
			var jd := maxi(j - 1, 0)
			var ju := mini(j + 1, n - 1)
			var dx := verts[j * n + ir] - verts[j * n + il]
			var dz := verts[ju * n + i] - verts[jd * n + i]
			normals[j * n + i] = dz.cross(dx).normalized()

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = fcols
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = idx

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_far_shell.mesh = mesh

	# 远景壳也要跟着当前地形的颜色走，否则默认白 tint 会在草原/森林里显出一大块白斑
	if _far_shell.material_override is ShaderMaterial and biome != null:
		var cdir := GeoSphere.tangent_to_dir(region_frame, pos.x, -pos.z)
		var bid := biome.biome_at(cdir)
		var sm2 := _far_shell.material_override as ShaderMaterial
		sm2.set_shader_parameter("biome_tint", BIOME_TINTS.get(bid, Color(0.55, 0.72, 0.40)))
		sm2.set_shader_parameter("biome_tint_strength", 0.82)
	print("[FarShell] 远景壳重建：%d ms（%d 顶点）" % [Time.get_ticks_msec() - t0, n * n])


func enable_streaming(radius: int = 1) -> void:
	_stream_radius = radius
	_stream_center = Vector2i(-99999, -99999)
	enable_far_shell()


## 传送到另一个地点：整张地图重建（视距内的地块会在随后几帧补上）
func travel_to(center_dir: Vector3, start_n: int = 1) -> void:
	_building.clear()
	build(center_dir, start_n, start_n, true)
	_stream_center = Vector2i(-99999, -99999)
	_far_center = Vector3(1e9, 0.0, 0.0)
	enable_far_shell()


func stream_radius() -> int:
	return _stream_radius


## 玩家局部坐标 -> 网格坐标（和 build() 完全同一套对齐）
func _grid_of(pos: Vector3) -> Vector2i:
	var size: float = cfg.tile_size_m
	return Vector2i(int(floorf(pos.x / size + _half_x)),
			int(floorf(-pos.z / size + _half_z)))


func _sid_for_ij(i: int, j: int) -> Vector3i:
	var size: float = cfg.tile_size_m
	var uc := (float(i) - _half_x + 0.5) * size
	var vc := (float(j) - _half_z + 0.5) * size
	return GeoSphere.dir_to_tile(GeoSphere.tangent_to_dir(region_frame, uc, vc))


func _free_at(ij: Vector2i) -> void:
	var t: TerrainTile = _grid.get(ij)
	if t == null:
		return
	_tiles.erase(t.sphere_tile)
	_grid.erase(ij)
	_building.erase(t)          # 别让构建队列还抓着已经释放的地块
	t.queue_free()


func _spawn_tile(i: int, j: int, do_scatter: bool, deferred: bool = false) -> TerrainTile:
	var size: float = cfg.tile_size_m
	var u0 := (float(i) - _half_x) * size
	var v0 := (float(j) - _half_z) * size
	var uc := u0 + size * 0.5
	var vc := v0 + size * 0.5
	var dir := GeoSphere.tangent_to_dir(region_frame, uc, vc)
	var sid := GeoSphere.dir_to_tile(dir)

	var bid := "plain"
	if biome != null:
		bid = biome.biome_at(dir)

	var tile := TerrainTile.new()
	tile.biome_id = bid
	tile.biome_parts = _biome_parts.get(bid, {})
	tile.biome_color = BIOME_TINTS.get(bid, Color.WHITE)
	tile.biome_map = biome
	tile.ground_material = _ground_material
	tile.prop_material = _prop_material
	tile.prop_meshes = _prop_meshes
	tile.designated = registry.near_tile(sid)
	tile.build_scatter = do_scatter
	tile.u0 = u0
	tile.v0 = v0
	tile.u_center = uc
	tile.v_center = vc
	tile.setup(Vector2i(i, j), sid, cfg, gen, region_frame)
	_tile_root.add_child(tile)

	if deferred:
		# 分帧：粗版立刻上，细节由 stream_update 每帧推一步
		tile.begin_job(do_scatter, true)
		_building.append(tile)
	else:
		tile.build()

	_tiles[sid] = tile
	_grid[Vector2i(i, j)] = tile
	tiles_ready += 1
	return tile


## 每帧调用：丢掉跑远的，补上缺的（每帧最多 1 个，避免掉帧）
func stream_update(pos: Vector3) -> void:
	if _stream_radius <= 0 or not _built:
		return
	_update_far_shell(pos)
	var c := _grid_of(pos)
	var r := _stream_radius

	# 1) 丢掉跑远的（r+1 留一圈余量，避免在边界上来回抖动时反复重建）
	for key in _grid.keys():
		var ij: Vector2i = key
		if ij == c:
			continue          # 玩家脚下那一块永远不释放，否则会掉进远景壳
		if maxi(absi(ij.x - c.x), absi(ij.y - c.y)) > r + 1:
			_free_at(ij)

	# 2) 硬上限：常驻不能无限涨，超了就扔掉最远的
	var cap := (2 * r + 1) * (2 * r + 1) + 6
	while _grid.size() > cap:
		var far := Vector2i(-99999, -99999)
		var far_d := -1
		for key2 in _grid.keys():
			var ij2: Vector2i = key2
			if ij2 == c:
				continue
			var d2 := maxi(absi(ij2.x - c.x), absi(ij2.y - c.y))
			if d2 > far_d:
				far_d = d2
				far = ij2
		if far.x == -99999:
			break
		_free_at(far)

	if c == _stream_center:
		pass
	_stream_center = c

	# 分帧构建：每帧只推进**最老的那个**任务一步，
	# 其余任务在队列里排队。粗版在 begin_job 时已经同步出好，所以不会有空洞。
	while not _building.is_empty() and not is_instance_valid(_building[0]):
		_building.pop_front()
	if not _building.is_empty():
		var job = _building[0]
		if job.step_job():
			_building.pop_front()
	# 往哪跑就先建哪：正前方的地块比分低的更急
	var dv := pos - _last_pos
	_last_pos = pos
	_vel = _vel * 0.85 + dv * 0.15
	var ahead := Vector2(_vel.x, -_vel.z)
	if ahead.length() > 0.02:
		ahead = ahead.normalized()
	else:
		ahead = Vector2.ZERO

	var best := Vector2i(-99999, -99999)
	var best_d := 99999.0
	for j in range(c.y - r, c.y + r + 1):
		for i in range(c.x - r, c.x + r + 1):
			if _grid.has(Vector2i(i, j)):
				continue
			var to := Vector2(float(i - c.x), float(j - c.y))
			var d := to.length()
			if ahead != Vector2.ZERO and d > 0.01:
				d -= to.normalized().dot(ahead) * 1.2   # 前方加权
			if d < best_d:
				best_d = d
				best = Vector2i(i, j)
	if best.x == -99999:
		return
	var t0 := Time.get_ticks_msec()
	_spawn_tile(best.x, best.y, _stream_radius > 0, true)
	print("[Stream] 生成地块 (%d,%d) 用时 %d ms  常驻 %d 块" % [best.x, best.y,
			Time.get_ticks_msec() - t0, _grid.size()])


func is_built() -> bool:
	return _built


## 加一个标注。别的模块随时可以加，地图只在画小地图时读它。
func add_annotation(a: MapAnnotation) -> void:
	annotations.append(a)


func add_annotations(list: Array) -> void:
	for a in list:
		if a is MapAnnotation:
			annotations.append(a)


## 区域根节点：相机、灯光挂到这下面，局部坐标就是 Y 朝上的切平面空间
func frame_node() -> Node3D:
	return _frame_root


func get_tile(t: Vector3i) -> TerrainTile:
	return _tiles.get(t)


func get_tiles() -> Dictionary:
	return _tiles


# ================================================================ 查询 API
## 地表高度（米），含选定地块的平台压平
func get_height_dir(dir: Vector3) -> float:
	var h := gen.height_at(dir)
	var tiles := registry.near_dir(dir)
	if tiles.is_empty():
		return h
	return DesignatedTileRegistry.apply_flatten(tiles, dir, h)


func get_height_lonlat(lon_deg: float, lat_deg: float) -> float:
	return get_height_dir(GeoSphere.lonlat_to_dir(lon_deg, lat_deg))


## 地表坡度（度）。每次调用要采样 4 次高度，别每帧每单位都用。
func get_slope_deg_dir(dir: Vector3) -> float:
	var e := 3.0
	var frame := GeoSphere.tangent_frame(dir)
	var pa := GeoSphere.tangent_to_dir(frame, e, 0.0)
	var pb := GeoSphere.tangent_to_dir(frame, -e, 0.0)
	var pc := GeoSphere.tangent_to_dir(frame, 0.0, e)
	var pd := GeoSphere.tangent_to_dir(frame, 0.0, -e)
	var dh_e := (get_height_dir(pa) - get_height_dir(pb)) / (2.0 * e)
	var dh_n := (get_height_dir(pc) - get_height_dir(pd)) / (2.0 * e)
	return rad_to_deg(atan(sqrt(dh_e * dh_e + dh_n * dh_n)))


func dir_to_tile(dir: Vector3) -> Vector3i:
	return GeoSphere.dir_to_tile(dir)


func designated_tile_at_dir(dir: Vector3) -> DesignatedTile:
	return registry.at_dir(dir)


# ================================================================ 坐标转换
## 球面方向 -> 区域局部渲染坐标（x=东, y=高度, z=南）。只给渲染用，不要存档。
func dir_to_render(dir: Vector3, height: float = NAN) -> Vector3:
	var h := get_height_dir(dir)
	if not is_nan(height):
		h = height
	return _local_from_dir(dir, h)


## 直接给出可以塞进 Vector3 的渲染位置（高度自动查地表）
func render_position(dir: Vector3, height_offset: float = 0.0) -> Vector3:
	return _local_from_dir(dir, get_height_dir(dir) + height_offset)


func _local_from_dir(dir: Vector3, h: float) -> Vector3:
	var up: Vector3 = region_frame["up"]
	var e: Vector3 = region_frame["east"]
	var n: Vector3 = region_frame["north"]
	var d := dir.normalized()
	var rr := GeoSphere.RADIUS_M + h
	var wx := float(d.x) * rr - float(up.x) * GeoSphere.RADIUS_M
	var wy := float(d.y) * rr - float(up.y) * GeoSphere.RADIUS_M
	var wz := float(d.z) * rr - float(up.z) * GeoSphere.RADIUS_M
	return Vector3(
			wx * float(e.x) + wy * float(e.y) + wz * float(e.z),
			wx * float(up.x) + wy * float(up.y) + wz * float(up.z),
			-(wx * float(n.x) + wy * float(n.y) + wz * float(n.z)))


# ================================================================ 内部
func _build_materials() -> void:
	_load_biomes()
	_ground_material = ShaderMaterial.new()
	var shader := load("res://shaders/terrain_splat.gdshader") as Shader
	if shader != null:
		_ground_material.shader = shader

	_ground_material.set_shader_parameter("tex_grass",
			TextureFactory.ground(Color(0.44, 0.55, 0.23), Color(0.25, 0.34, 0.12), 101))
	_ground_material.set_shader_parameter("tex_dirt",
			TextureFactory.ground(Color(0.53, 0.41, 0.27), Color(0.31, 0.23, 0.15), 202))
	_ground_material.set_shader_parameter("grass_dirt_lo", cfg.grass_dirt_lo)
	_ground_material.set_shader_parameter("grass_dirt_hi", cfg.grass_dirt_hi)
	_ground_material.set_shader_parameter("show_white_model", false)

	_prop_material = StandardMaterial3D.new()
	_prop_material.vertex_color_use_as_albedo = true
	_prop_material.roughness = 0.92
	_prop_material.metallic = 0.0

	_prop_meshes = {
		"tree": PropMeshes.tree(),
		"rock": PropMeshes.rock(),
		"low_veg": PropMeshes.low_veg(),
	}


func set_white_model(on: bool) -> void:
	if _ground_material != null:
		_ground_material.set_shader_parameter("show_white_model", on)


## 把落在本区域内的选定地块通报出去。默认表是空的，这里就什么也不做。
func _place_designated() -> void:
	if registry.is_empty():
		return

	for entry in registry.all():
		var dt := entry as DesignatedTile
		if dt == null:
			continue
		var cdir := dt.center_dir()
		if not _dir_in_region(cdir):
			continue

		var pos := _local_from_dir(cdir, dt.resolved_height)
		if cfg.show_designated_markers:
			_make_marker(dt, pos)
		designated_tile_placed.emit(dt, pos)


## 这个方向是不是落在当前已铺的区域内（粗略判断，够用）
func _dir_in_region(dir: Vector3) -> bool:
	var reach := maxf(float(_tiles_x), float(_tiles_z)) * cfg.tile_size_m * 0.75 + 600.0
	return GeoSphere.distance_m(region_center_dir, dir) <= reach


## 调试用的占位标记：默认关闭。正式内容由你的模块挂在 designated_tile_placed 上。
func _make_marker(dt: DesignatedTile, pos: Vector3) -> void:
	var mark_r := minf(dt.flatten_radius_m * 0.16, 60.0)
	var disc := CylinderMesh.new()
	disc.top_radius = mark_r
	disc.bottom_radius = mark_r * 1.06
	disc.height = 2.0
	disc.radial_segments = 48
	disc.rings = 1

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.53, 0.48)
	mat.roughness = 0.96

	var mi := MeshInstance3D.new()
	mi.name = "Marker_" + dt.id
	mi.mesh = disc
	mi.material_override = mat
	mi.position = Vector3(pos.x, pos.y - 0.7, pos.z)
	_marker_root.add_child(mi)


func _clear_children(n: Node) -> void:
	if n == null:
		return
	for c in n.get_children():
		n.remove_child(c)
		c.queue_free()


## 读地形表 + 海陆掩膜，建生物群系判定器
func _load_biomes() -> void:
	var mask: Image = null
	var mt := load("res://data/earth_land_mask.png") as Texture2D
	if mt != null:
		mask = mt.get_image()
	biome = BiomeMap.new()
	biome.setup(gen, mask)

	var path := "res://data/terrain_types.json"
	if not FileAccess.file_exists(path):
		return
	var txt := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY:
		return
	for t in data.get("terrain_types", []):
		var v: Dictionary = t.get("vegetation", {})
		_biome_parts[t.get("id", "")] = {
			"tree": v.get("trees", []),
			"rock": v.get("rocks", []),
			# 内部 kind 叫 low_veg，JSON 字段叫 low，这里统一成 low_veg
			"low_veg": v.get("low", []),
		}
	print("[Map] 生物群系表载入：%d 类" % _biome_parts.size())
