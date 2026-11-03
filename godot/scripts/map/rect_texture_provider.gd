class_name RectTextureProvider
extends MapTextureProvider

## ==============================================================
## 按"视野矩形"生成一块高清图（不切瓦片）
##
## 为什么不用瓦片：我们的地形是程序生成的，瓦片的分块好处用不上，
## 反而要处理边界对齐、垫底、覆盖不足。整块生成 →
## **只有一张图，结构上不可能有缝**。
##
## 两阶段分帧：
##   0 逐行采高程   1 逐行着色（高程配色 + 山体阴影）
## ==============================================================

const CACHE_DIR := "user://region_cache"

var _h := PackedFloat32Array()
var _img: Image
var _row := 0
var _phase := 0
var _px := 0
var _lon0 := 0.0
var _lon1 := 0.0
var _lat0 := 0.0
var _lat1 := 0.0
var _span_m := 1.0
var _world: MapWorld
var _key := ""


func try_cached_rect(key: String) -> Image:
	var path := "%s/rect_%s.png" % [CACHE_DIR, key]
	if not FileAccess.file_exists(path):
		return null
	return Image.load_from_file(path)


## 开始生成：矩形用经纬度给
func begin_rect(world: MapWorld, lon0: float, lat0: float, lon1: float, lat1: float,
		px: int, key: String) -> void:
	_world = world
	_px = px
	_row = 0
	_phase = 0
	_lon0 = lon0
	_lon1 = lon1
	_lat0 = lat0
	_lat1 = lat1
	_key = key
	_span_m = absf(lon1 - lon0) * 111000.0
	_h = PackedFloat32Array()
	_h.resize(px * px)
	_img = null


func step(max_rows: int) -> float:
	if _px <= 0:
		return 1.0
	var y1 := mini(_row + max_rows, _px)
	if _phase == 0:
		for j in range(_row, y1):
			var lat := lerpf(_lat1, _lat0, float(j) / float(_px - 1))
			for i in _px:
				var lon := lerpf(_lon0, _lon1, float(i) / float(_px - 1))
				var d := GeoSphere.lonlat_to_dir(lon, lat)
				_h[j * _px + i] = _world.get_height_dir(d) if _world != null else 0.0
		_row = y1
		if y1 >= _px:
			_phase = 1
			_row = 0
			_img = Image.create(_px, _px, false, Image.FORMAT_RGB8)
		return 0.55 * float(y1) / float(_px)

	_shade(_row, y1)
	_row = y1
	return 0.55 + 0.45 * float(y1) / float(_px)


func _shade(y0: int, y1: int) -> void:
	var px := _px
	var light := Vector3(-0.55, 0.62, 0.56).normalized()
	var spacing := _span_m / float(px)
	for j in range(y0, y1):
		for i in px:
			var h := _h[j * px + i]
			var c: Color
			if h < 0.0:
				c = Color(0.10, 0.22, 0.38)
			elif h < 30.0:
				c = Color(0.26, 0.42, 0.28)
			elif h < 70.0:
				c = Color(0.32, 0.46, 0.27)
			elif h < 120.0:
				c = Color(0.38, 0.49, 0.27)
			elif h < 200.0:
				c = Color(0.46, 0.51, 0.29)
			elif h < 320.0:
				c = Color(0.55, 0.54, 0.34)
			elif h < 600.0:
				c = Color(0.62, 0.52, 0.38)
			elif h < 1000.0:
				c = Color(0.58, 0.50, 0.46)
			else:
				c = Color(0.86, 0.86, 0.84)
			if h >= 0.0:
				var il := maxi(i - 1, 0)
				var ir := mini(i + 1, px - 1)
				var jd := maxi(j - 1, 0)
				var ju := mini(j + 1, px - 1)
				var dx := (_h[j * px + ir] - _h[j * px + il]) / (2.0 * spacing) * 8.0
				var dz := (_h[ju * px + i] - _h[jd * px + i]) / (2.0 * spacing) * 8.0
				var n := Vector3(-dx, 1.0, -dz).normalized()
				var lit := clampf(n.dot(light) * 1.4, 0.45, 1.35)
				c = Color(c.r * lit, c.g * lit, c.b * lit)
			_img.set_pixel(i, j, c)


func is_done() -> bool:
	return _phase == 1 and _row >= _px


func take() -> Image:
	var out := _img
	_img = null
	return out


func save_rect(key: String, img: Image) -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	img.save_png("%s/rect_%s.png" % [CACHE_DIR, key])
