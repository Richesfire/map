class_name MapMinimap
extends Control

## ==============================================================
## 小地图
##
## 两种模式，M 键切换：
##   * 局部：以当前区域为中心，约 2.6km 见方，看得到地形起伏、坡度、
##           选定地块位置、标注、玩家位置与朝向
##   * 全球：把整个地球画成一个球，标出玩家所在半球和所有标注
##
## 图不是用第二个相机渲染的，是**直接在 CPU 上采样地形函数**画出来的。
## 好处：不需要额外的 Viewport / 光照 / LOD，也不受雾和阴影影响，
##       测出来的就是地形本身。代价是切模式时有一次几十毫秒的生成。
##
## 用法：
##     var mm := MapMinimap.new()
##     add_child(mm)
##     mm.setup(map, player_camera)
## ==============================================================

enum Mode { LOCAL, GLOBE }

const RES := 192                 # 小地图纹理分辨率
const COL_GRASS := Color(0.36, 0.50, 0.20)
const COL_DIRT := Color(0.52, 0.40, 0.26)
const COL_WATER := Color(0.13, 0.22, 0.31)
const COL_SPACE := Color(0.05, 0.07, 0.10)

@export var local_span_m := 2600.0

var world: MapWorld
var player: Node3D
var annotations: Array = []
var mode: int = Mode.LOCAL
var globe_center := Vector3.UP

var _tex: ImageTexture
var _font: Font
var _pixel := 220.0
var _tex_center_uv := Vector2.ZERO   # 底图中心在切平面上的（东,北）米
var _dialog: WorldMapDialog


func setup(map: MapWorld, player_node: Node3D, annotations_list: Array = []) -> void:
	world = map
	player = player_node
	annotations = annotations_list
	_font = _load_cjk_font()
	custom_minimum_size = Vector2(_pixel, _pixel)
	size = Vector2(_pixel, _pixel)
	globe_center = world.region_center_dir
	refresh()
	queue_redraw()


func toggle_mode() -> void:
	mode = Mode.GLOBE if mode == Mode.LOCAL else Mode.LOCAL
	if mode == Mode.GLOBE:
		globe_center = world.region_center_dir
	refresh()
	queue_redraw()


## 重新生成底图。切区域、切模式、改 seed 之后调用。
func refresh() -> void:
	if world == null or world.gen == null:
		return
	if mode == Mode.LOCAL:
		_tex = _build_local()
	else:
		_tex = _build_globe()
	queue_redraw()


func _process(_delta: float) -> void:
	if player != null:
		if mode == Mode.LOCAL:
			var uv := _player_uv()
			if uv.distance_to(_tex_center_uv) > local_span_m * 0.30:
				_tex_center_uv = uv
				refresh()
		queue_redraw()


# ================================================================ 底图生成
func _build_local() -> ImageTexture:
	var img := Image.create(RES, RES, false, Image.FORMAT_RGB8)
	var frame := world.region_frame
	var span := local_span_m
	var step := span / float(RES)

	var hs := PackedFloat32Array()
	hs.resize(RES * RES)
	for y in RES:
		var v := ((float(y) + 0.5) / float(RES) - 0.5) * span
		var row := y * RES
		for x in RES:
			var u := _tex_center_uv.x + ((float(x) + 0.5) / float(RES) - 0.5) * span
			hs[row + x] = world.get_height_dir(GeoSphere.tangent_to_dir(frame, u, v))

	# 光从西北来
	var light := Vector3(-0.5, 0.8, -0.35).normalized()
	for y in RES:
		for x in RES:
			var i := y * RES + x
			var hl := hs[y * RES + maxi(x - 1, 0)]
			var hr := hs[y * RES + mini(x + 1, RES - 1)]
			var hu := hs[maxi(y - 1, 0) * RES + x]
			var hd := hs[mini(y + 1, RES - 1) * RES + x]
			var gx := (hr - hl) / (2.0 * step)
			var gy := (hd - hu) / (2.0 * step)
			var n := Vector3(-gx, 1.0, -gy).normalized()
			var shade := clampf(n.dot(light), 0.15, 1.0)
			var slope := rad_to_deg(atan(sqrt(gx * gx + gy * gy)))
			var w := smoothstep(8.0, 26.0, slope)
			var c := COL_GRASS.lerp(COL_DIRT, w) * (0.55 + 0.75 * shade)
			img.set_pixel(x, y, Color(clampf(c.r, 0.0, 1.0), clampf(c.g, 0.0, 1.0),
					clampf(c.b, 0.0, 1.0)))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _build_globe() -> ImageTexture:
	var img := Image.create(RES, RES, false, Image.FORMAT_RGB8)
	var fwd := globe_center.normalized()
	var right := Vector3.UP.cross(fwd)
	if right.length_squared() < 1e-8:
		right = Vector3.RIGHT.cross(fwd)
	right = right.normalized()
	var upv := fwd.cross(right).normalized()

	# 先采一遍高度，拿到这一屏的取值范围好上色
	var hs := PackedFloat32Array()
	hs.resize(RES * RES)
	var hmin := 1e9
	var hmax := -1e9
	for y in RES:
		var sy := 1.0 - (float(y) + 0.5) / float(RES) * 2.0
		for x in RES:
			var sx := (float(x) + 0.5) / float(RES) * 2.0 - 1.0
			var i := y * RES + x
			if sx * sx + sy * sy > 1.0:
				hs[i] = NAN
				continue
			var dir := (fwd + right * sx + upv * sy).normalized()
			var h := world.get_height_dir(dir)
			hs[i] = h
			hmin = minf(hmin, h)
			hmax = maxf(hmax, h)

	if hmax - hmin < 1.0:
		hmax = hmin + 1.0

	for y in RES:
		var sy := 1.0 - (float(y) + 0.5) / float(RES) * 2.0
		for x in RES:
			var sx := (float(x) + 0.5) / float(RES) * 2.0 - 1.0
			var i := y * RES + x
			var rr := sx * sx + sy * sy
			if rr > 1.0:
				img.set_pixel(x, y, COL_SPACE)
				continue
			var t := (hs[i] - hmin) / (hmax - hmin)
			var c := Color(0.22, 0.34, 0.16).lerp(Color(0.62, 0.55, 0.36), t)
			# 边缘压暗，做出球感
			c = c * (0.45 + 0.75 * sqrt(maxf(0.0, 1.0 - rr)))
			img.set_pixel(x, y, Color(clampf(c.r, 0.0, 1.0), clampf(c.g, 0.0, 1.0),
					clampf(c.b, 0.0, 1.0)))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# ================================================================ 投影
## 方向 -> 小地图像素。看不到就返回 Vector2(-1,-1)。
func _project(dir: Vector3) -> Vector2:
	var half := size * 0.5
	if mode == Mode.LOCAL:
		var off := GeoSphere.dir_to_tangent(world.region_frame, dir)
		var pu := _player_uv()
		var k := size.x / local_span_m
		var p := Vector2(half.x + (off.x - pu.x) * k, half.y - (off.y - pu.y) * k)
		if p.x < 0.0 or p.y < 0.0 or p.x > size.x or p.y > size.y:
			return Vector2(-1.0, -1.0)
		return p

	var fwd := globe_center.normalized()
	var right := Vector3.UP.cross(fwd)
	if right.length_squared() < 1e-8:
		right = Vector3.RIGHT.cross(fwd)
	right = right.normalized()
	var upv := fwd.cross(right).normalized()
	var d := dir.normalized()
	if d.dot(fwd) <= 0.05:
		return Vector2(-1.0, -1.0)
	var x := d.dot(right)
	var y := d.dot(upv)
	return Vector2(half.x + x * half.x, half.y - y * half.y)


# ================================================================ 绘制
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.04), true)
	if _tex != null:
		draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false)

	# 选定地块：画方框
	if world != null:
		for entry in world.registry.all():
			var dt := entry as DesignatedTile
			if dt == null:
				continue
			var p := _project(dt.center_dir())
			if p.x < 0.0:
				continue
			var half_span := size.x / local_span_m * float(dt.size_tiles) * world.cfg.tile_size_m * 0.5
			draw_rect(Rect2(p - Vector2(half_span, half_span),
					Vector2(half_span, half_span) * 2.0), Color(1, 0.85, 0.3, 0.9), false, 1.5)

	# 全球模式先画经纬网格，球才读得懂
	if mode == Mode.GLOBE:
		_draw_graticule()

	# 标注：点 + 名字
	var list: Array = world.annotations if world != null else annotations
	for entry in list:
		var a := entry as MapAnnotation
		if a == null:
			continue
		var p := _project(a.dir)
		if p.x < 0.0:
			continue
		draw_circle(p, 3.0, Color(0.08, 0.05, 0.02, 0.9))
		draw_circle(p, 2.2, Color(1.0, 0.82, 0.35))
		if mode == Mode.LOCAL and _font != null:
			draw_string(_font, p + Vector2(5, 4), a.label, HORIZONTAL_ALIGNMENT_LEFT,
					-1, 11, Color(1, 1, 1, 0.95))

	# 玩家：三角形指向朝向
	if player != null and world != null:
		var facing := -player.transform.basis.z
		var east_f := facing.x
		var north_f := -facing.z
		var p2 := _player_pixel()
		if p2.x >= 0.0:
			var ang := atan2(north_f, east_f)
			var fwd := Vector2(cos(ang), -sin(ang))
			var side := Vector2(-fwd.y, fwd.x)
			var pts := PackedVector2Array([
				p2 + fwd * 7.0,
				p2 - fwd * 4.0 + side * 4.0,
				p2 - fwd * 4.0 - side * 4.0,
			])
			draw_colored_polygon(pts, Color(1.0, 0.35, 0.25))

	# 边框 + 模式字样
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.75), false, 2.0)
	if _font != null:
		var tag := "LOCAL %.1fkm" % (local_span_m / 1000.0) if mode == Mode.LOCAL else "GLOBE"
		draw_string(_font, Vector2(8, size.y - 8), tag, HORIZONTAL_ALIGNMENT_LEFT,
				-1, 11, Color(1, 1, 1, 0.75))


## 每 30 度一根经纬线，让"球"变成"地图"
func _draw_graticule() -> void:
	var c := Color(1, 1, 1, 0.35)
	var i := -180
	while i < 180:
		_stroke_meridian(float(i), c)
		i += 30
	var lat := -60
	while lat <= 60:
		_stroke_parallel(float(lat), c)
		lat += 30


func _stroke_meridian(lon_deg: float, c: Color) -> void:
	var prev := Vector2(-1, -1)
	var lat := -88.0
	while lat <= 88.0:
		var p := _project(GeoSphere.lonlat_to_dir(lon_deg, lat))
		if p.x >= 0.0 and prev.x >= 0.0:
			draw_line(prev, p, c, 1.0)
		prev = p
		lat += 4.0


func _stroke_parallel(lat_deg: float, c: Color) -> void:
	var prev := Vector2(-1, -1)
	var lon := -180.0
	while lon <= 180.0:
		var p := _project(GeoSphere.lonlat_to_dir(lon, lat_deg))
		if p.x >= 0.0 and prev.x >= 0.0:
			draw_line(prev, p, c, 1.0)
		prev = p
		lon += 4.0


func _player_uv() -> Vector2:
	if player == null:
		return Vector2.ZERO
	return Vector2(player.position.x, -player.position.z)


func _player_pixel() -> Vector2:
	if mode == Mode.LOCAL:
		return size * 0.5      # 人物永远在中心，底图跟着人跑
	# 全球模式：玩家在区域中心方向
	return _project(world.region_center_dir)


# ================================================================ 大地图

func open_world_map() -> void:
	if world == null:
		return
	if _dialog == null or not is_instance_valid(_dialog):
		_dialog = WorldMapDialog.new()
		_dialog.name = "WorldMapDialog"
		var host := get_parent()
		if host != null:
			host.add_child(_dialog)
		else:
			add_child(_dialog)
	_dialog.open(world, world.annotations, world.region_center_dir)


func get_dialog() -> WorldMapDialog:
	return _dialog


## 在进入游戏的黑屏期间把地球仪和它的贴图先建好，
## 这样第一次按 M 是瞬间打开的。
func prewarm_world_map() -> void:
	if world == null:
		return
	open_world_map()
	var dlg := get_dialog()
	if dlg != null:
		# 等地球贴图生成完（open() 内部是协程）
		for i in 400:
			await get_tree().process_frame
			if dlg.is_ready_for_map():
				break
	close_world_map()


func close_world_map() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.close()


# ================================================================ 字体
## Godot 默认字体没有中文字形，标注名会变成方块。
## 这里试着加载系统里的中文字体，找不到就退回默认字体（英文能显示）。
static func _load_cjk_font() -> Font:
	var candidates := [
		"C:/Windows/Fonts/msyh.ttc",
		"C:/Windows/Fonts/msyh.ttf",
		"C:/Windows/Fonts/simhei.ttf",
		"C:/Windows/Fonts/simsun.ttc",
		"C:/Windows/Fonts/msjh.ttc",
	]
	for path in candidates:
		if not FileAccess.file_exists(path):
			continue
		var f := FontFile.new()
		if f.load_dynamic_font(path) == OK:
			return f
	return ThemeDB.fallback_font
